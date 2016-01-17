#!/usr/bin/env ruby
#
# check-rancher-service.rb
#
# Author: Matteo Cerutti <matteo.cerutti@hotmail.co.uk>
#

require 'sensu-plugin/check/cli'
require 'net/http'
require 'json'
require' fileutils'

class CheckRancherService < Sensu::Plugin::Check::CLI
  option :api_url,
         :description => "Rancher Metadata API URL (default: http://rancher-metadata/2015-07-25)",
         :long => "--api-url <URL>",
         :proc => proc { |s| s.gsub(/\/$/, '') },
         :default => "http://rancher-metadata/2015-07-25"

  option :state_dir,
         :description => "State directory",
         :long => "--state-dir <PATH> (default: /var/cache/check-rancher-service)",
         :default => "/var/cache/check-rancher-service"

  option :handlers,
         :description => "Comma separated list of handlers",
         :long => "--handlers <HANDLER>",
         :proc => proc { |s| s.split(',') },
         :default => []

  option :dryrun,
         :description => "Do not send events to sensu client socket",
         :long => "--dryrun",
         :boolean => true,
         :default => false

  def initialize()
    super

    # prepare state directory
    FileUtils.mkdir_p(config[:state_dir]) unless File.directory?(config[:state_dir])

    @state_file = config[:state_dir] + "/containers.json"
  end

  def read_state()
    if File.exists?(@state_file)
      JSON.parse(File.read(@state_file))
    else
      {}
    end
  end

  def write_state(state)
    File.open(@state_file, 'w') { |f| f.write(state) }
  end

  def send_client_socket(data)
    if config[:dryrun]
      puts data.inspect
    else
      sock = UDPSocket.new
      sock.send(data + "\n", 0, "127.0.0.1", 3030)
    end
  end

  def send_ok(check_name, source, msg)
    event = {"name" => check_name, "source" => source, "status" => 0, "output" => "#{self.class.name} OK: #{msg}", "handlers" => config[:handlers]}
    send_client_socket(event.to_json)
  end

  def send_warning(check_name, source, msg)
    event = {"name" => check_name, "source" => source, "status" => 1, "output" => "#{self.class.name} WARNING: #{msg}", "handlers" => config[:handlers]}
    send_client_socket(event.to_json)
  end

  def send_critical(check_name, source, msg)
    event = {"name" => check_name, "source" => source, "status" => 2, "output" => "#{self.class.name} CRITICAL: #{msg}", "handlers" => config[:handlers]}
    send_client_socket(event.to_json)
  end

  def send_unknown(check_name, source, msg)
    event = {"name" => check_name, "source" => source, "status" => 3, "output" => "#{self.class.name} UNKNOWN: #{msg}", "handlers" => config[:handlers]}
    send_client_socket(event.to_json)
  end

  def is_error?(data)
    if data.is_a?(Hash) and data.has_key?('code') and data['code'] == 404
      return true
    else
      return false
    end
  end

  def api_get(query)
    begin
      uri = URI.parse("#{config[:api_url]}#{query}")
      req = Net::HTTP::Get.new(uri.path, {'Content-Type' => 'application/json', 'Accept' => 'application/json'})
      resp = Net::HTTP.new(uri.host, uri.port).request(req)
      data = JSON.parse(resp.body)

      if is_error?(data)
        return nil
      else
        return data
      end
    rescue
      raise "Failed to query Rancher Metadata API - Caught exception (#{$!})"
    end
  end

  def get_services()
    api_get("/services")
  end

  def get_container(name)
    api_get("/containers/#{name}")
  end

  def run
    unmonitored = 0
    unhealthy = 0

    # read current state
    state = read_state()

    get_services().each do |service|
      source = "#{service['stack_name']}_#{service['name']}.rancher.internal"

      if service['metadata'].has_key?('sensu') and service['metadata']['sensu'].has_key?('monitored')
        monitored = service['metadata']['sensu']['monitored']
      else
        monitored = true
      end

      # get containers
      service['containers'].each do |container_name|
        check_name = "rancher-container-#{container_name}-state"
        msg = "Instance #{container_name}"

        unless monitored
          send_ok(check_name, source, "#{msg} not monitored (disabled)")
        else
          container = get_container(container_name)

          skip = false
          if state.has_key?(container_name)
            if container['start_count'] > state[container_name]['start_count']
              send_warning(check_name, source, "#{msg} has restarted")
              skip = true
            end
          else
            state[container_name] = {}
          end

          # update state
          state[container_name]['start_count'] = container['start_count']

          next if skip

          # check if the service restarted
          case container['health_state']
            when 'healthy'
              send_ok(check_name, source, "#{msg} is healthy")

            when nil
              send_warning(check_name, source, "#{msg} not monitored")
              unmonitored += 1

            else
              send_critical(check_name, source, "#{msg} is not healthy")
              unhealthy += 1
          end
        end
      end
    end

    # persist state to disk
    write_state(state)

    # check service scale size to determine whether it's degraded or not
    check_name = "rancher-service-state"
    if service['containers'].size < service['scale']
      send_warning(check_name, source, "Service is in a degraded state - Current: #{service['containers'].size} (Scale: #{service['scale']})")
    else
      send_ok(check_name, source, "Service is healthy")
    end

    critical("Found #{unhealthy} unhealthy instances") if unhealthy > 0
    warning("Found #{unmonitored} instances not begin monitored") if unmonitored > 0
    ok("All Rancher services instances are healthy")
  end
end
