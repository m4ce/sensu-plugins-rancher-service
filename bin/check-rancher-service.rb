#!/usr/bin/env ruby
#
# check-rancher-service.rb
#
# Author: Matteo Cerutti <matteo.cerutti@hotmail.co.uk>
#

require 'sensu-plugin/check/cli'
require 'net/http'
require 'json'

class CheckRancherService < Sensu::Plugin::Check::CLI
  option :api_url,
         :description => "Rancher Metadata API URL (default: http://rancher-metadata/2015-07-25)",
         :long => "--api-url <URL>",
         :proc => proc { |s| s.gsub(/\/$/, '') },
         :default => "http://rancher-metadata/2015-07-25"

  option :dryrun,
         :description => "Do not send events to sensu client socket",
         :long => "--dryrun",
         :boolean => true,
         :default => false

  def initialize()
    super
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
    event = {"name" => check_name, "source" => source, "status" => 0, "output" => "OK: #{msg}"}
    send_client_socket(event.to_json)
  end

  def send_warning(check_name, source, msg)
    event = {"name" => check_name, "source" => source, "status" => 1, "output" => "WARNING: #{msg}"}
    send_client_socket(event.to_json)
  end

  def send_critical(check_name, source, msg)
    event = {"name" => check_name, "source" => source, "status" => 2, "output" => "CRITICAL: #{msg}"}
    send_client_socket(event.to_json)
  end

  def send_unknown(check_name, source, msg)
    event = {"name" => check_name, "source" => source, "status" => 3, "output" => "UNKNOWN: #{msg}"}
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

    get_services().each do |service|
      source = "#{service['stack_name']}_#{service['name']}.rancher.internal"

      if service['metadata'].has_key?('sensu') and service['metadata']['sensu'].has_key?('monitored')
        monitored = service['metadata']['sensu']['monitored']
      else
        monitored = true
      end

      # get containers
      service['containers'].each do |container_name|
        check_name = "rancher-container-#{container_name}-health_state"
        msg = "Instance #{container_name}"

        unless monitored
          send_ok(check_name, source, "#{msg} not monitored (disabled)")
        else
          health_state = get_container(container_name)['health_state']
          case health_state
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

    critical("Found #{unhealthy} unhealthy instances") if unhealthy > 0
    warning("Found #{unmonitored} instances not begin monitored") if unmonitored > 0
    ok("All Rancher services instances are healthy")
  end
end
