# Sensu plugin for monitoring services running in Rancher

A sensu plugin to monitor the health state of services running in Rancher.

The plugin leverages the Sensu JIT clients feature (https://sensuapp.org/docs/latest/clients#jit-clients) to create a client for every
Rancher service discovered. The client name is in the format: \<stack_name>_\<service_name>.rancher.internal.

It then generates for every instance (container) running in the service OK/WARN/CRIT/UNKNOWN events via the sensu client socket
(https://sensuapp.org/docs/latest/clients#client-socket-input), reporting whether the instance is not monitored (WARN), healthy (OK) or unhealthy (CRITICAL).

You can optionally disable monitoring for a service by placing in the rancher-compose service metadata the following:

```
service:
  metadata:
    sensu:
      monitored: false
```

## Usage

The plugin accepts the following command line options:

```
Usage: check-rancher-service.rb (options)
        --api-url <URL>              Rancher Metadata API URL (default: http://rancher-metadata/2015-07-25)
        --dryrun                     Do not send events to sensu client socket
    -w, --warn                       Warn instead of throwing a critical failure
```

## Deployment

In order to run this check, you might want to deploy a sensu-client running as a container in Rancher, acting as a "sensu proxy".

## Author
Matteo Cerutti - <matteo.cerutti@hotmail.co.uk>
