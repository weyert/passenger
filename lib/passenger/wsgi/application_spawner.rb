#  Phusion Passenger - http://www.modrails.com/
#  Copyright (C) 2008  Phusion
#
#  This program is free software; you can redistribute it and/or modify
#  it under the terms of the GNU General Public License as published by
#  the Free Software Foundation; version 2 of the License.
#
#  This program is distributed in the hope that it will be useful,
#  but WITHOUT ANY WARRANTY; without even the implied warranty of
#  MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
#  GNU General Public License for more details.
#
#  You should have received a copy of the GNU General Public License along
#  with this program; if not, write to the Free Software Foundation, Inc.,
#  51 Franklin Street, Fifth Floor, Boston, MA 02110-1301 USA.

require 'socket'
require 'passenger/application'
require 'passenger/message_channel'
require 'passenger/utils'
module Passenger
module WSGI

# Class for spawning WSGI applications.
class ApplicationSpawner
	include Utils
	REQUEST_HANDLER = File.expand_path(File.dirname(__FILE__) + "/request_handler.py")
	
	def self.spawn_application(*args)
		@@instance ||= ApplicationSpawner.new
		@@instance.spawn_application(*args)
	end
	
	# Spawn an instance of the given WSGI application. When successful, an
	# Application object will be returned, which represents the spawned
	# application.
	#
	# Raises:
	# - AppInitError: The WSGI application raised an exception or called
	#   exit() during startup.
	# - SystemCallError, IOError, SocketError: Something went wrong.
	def spawn_application(app_root, lower_privilege = true, lowest_user = "nobody", environment = "production")
		a, b = UNIXSocket.pair
		# Double fork in order to prevent zombie processes.
		pid = safe_fork(self.class.to_s) do
			safe_fork(self.class.to_s) do
				a.close
				run(MessageChannel.new(b), app_root, lower_privilege, lowest_user, environment)
			end
		end
		b.close
		Process.waitpid(pid) rescue nil
		
		channel = MessageChannel.new(a)
		pid, socket_name, using_abstract_namespace = channel.read
		if pid.nil?
			raise IOError, "Connection closed"
		end
		owner_pipe = channel.recv_io
		return Application.new(@app_root, pid, socket_name,
			using_abstract_namespace == "true", owner_pipe)
	end

private
	def run(channel, app_root, lower_privilege, lowest_user, environment)
		$0 = "WSGI: #{app_root}"
		ENV['WSGI_ENV'] = environment
		Dir.chdir(app_root)
		if lower_privilege
			lower_privilege('passenger_wsgi.py', lowest_user)
		end
		
		socket_file = "/tmp/passenger_wsgi.#{Process.pid}.#{rand 10000000}"
		server = UNIXServer.new(socket_file)
		begin
			reader, writer = IO.pipe
			channel.write(Process.pid, socket_file, "false")
			channel.send_io(writer)
			writer.close
			channel.close
			
			NativeSupport.close_all_file_descriptors([0, 1, 2, server.fileno,
				reader.fileno])
			exec(REQUEST_HANDLER, socket_file, server.fileno.to_s,
				reader.fileno.to_s)
		rescue
			File.unlink(socket_file)
			raise
		end
	end
end

end # module WSGI
end # module Passenger
