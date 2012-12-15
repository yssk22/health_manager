require 'schemata/dea'

module HealthManager

  #this implementation maintains the known state by listening to the
  #DEA heartbeat messages
  class NatsBasedKnownStateProvider < KnownStateProvider
    def initialize(config = {})
      @config = config
      super
    end

    def cc_partition_match?(message)
      msg_partition = message.kind_of?(Hash) ?
        message['cc_partition'] : message.cc_partition
      cc_partition == msg_partition
    end

    def start
      logger.info("subscribing to heartbeats")
      NATS.subscribe('dea.heartbeat') do |message|
        message = Schemata::DEA::HeartbeatResponse.decode(message)
        process_heartbeat(message)
      end

      logger.info("subscribing to droplet.exited")
      NATS.subscribe('droplet.exited') do |message|
        message = Schemata::DEA::ExitMessage.decode(message)
        process_droplet_exited(message)
      end

      logger.info("subscribing to droplet.updated")
      NATS.subscribe('droplet.updated') do |message|
        process_droplet_updated(message)
      end

      super
    end

    def process_droplet_exited(message)
      return unless cc_partition_match?(message)

      logger.debug { "process_droplet_exited: #{message.contents}" }
      varz.inc(:droplet_exited_msgs_received)

      droplet = get_droplet(message.droplet.to_s)

      case message.reason
      when CRASHED
        varz.inc(:crashed_instances)
        droplet.process_exit_crash(message)
      when DEA_SHUTDOWN, DEA_EVACUATION
        droplet.process_exit_dea(message)
      when STOPPED
        droplet.process_exit_stopped(message)
      end
    end

    def process_heartbeat(message)
      logger.debug2 { "known: #process_heartbeat: #{message.contents}" }
      varz.inc(:heartbeat_msgs_received)

      dea_uuid = message.dea

      message.droplets.each do |beat|
        next unless cc_partition_match?(beat)
        id = beat['droplet'].to_s
        get_droplet(id).process_heartbeat(beat)
      end
    end

    def process_droplet_updated(message_str)
      message = parse_json(message_str)
      return unless cc_partition_match?(message)

      logger.debug { "known: #process_droplet_updated: #{message_str}" }
      varz.inc(:droplet_updated_msgs_received)
      get_droplet(message['droplet'].to_s).process_droplet_updated(message)
    end
  end
end
