require 'scout'

UNIT_PATTERN_TO_APP = {
  /scrivitocom/ => "dashboard",
  /crm/ => "crm",
  /console/ => "console",
  /scriv.*cms/ => "backend",
  /cms/ => "cms",
}

class LastEvent
  class Identity < Struct.new(:hostname, :pid, :stack_id)

    class << self
      def for(event)
        identity = event.attributes[:identity] or
            raise "Missing identity in event: attributes = #{event.attributes}"
        hostname, pid, stack_id = identity.split(":")
        raise "Unexpected identity #{identity} - cannot split by :" unless pid
        raise "Unexpected pid #{pid} from identity #{identity}" unless pid.to_i.to_s == pid
        new(hostname, pid, stack_id)
      end

      def hostname
        @hostname ||= `hostname`.strip
      end
    end
  end

  def initialize(execution, swf_config)
    @execution = execution
    @swf_config = swf_config
  end

  def event_type
    event.event_type
  end

  def zombie?
    if aws_expects_running_here? && !running?
      # the inspected event is still the last event of the execution
      if event.id == current_last_event_of_execution.id
        log_zombie
        true
      end
    end
  end

  def running?
    File.exists?("/proc/#{identity.pid}")
  end

  def app_name
    (@app_name ||= [compute_app_name || "unknown"]).first
  end

  private

  attr_reader :execution, :swf_config

  def first_event_attributes
    @first_event_attributes ||= execution.history_events.first.attributes
  end

  def compute_app_name
    input_as_json = first_event_attributes[:input]
    if input_as_json
      input = JSON(input_as_json)
      unit = input["unit"]
      match = UNIT_PATTERN_TO_APP.keys.detect {|pattern, app| unit =~ pattern}
      if match
        UNIT_PATTERN_TO_APP[match]
      end
    end
  end

  def aws_expects_running_here?
    identity.hostname == Identity.hostname && !foreign_stack?
  end

  # requires stack_id to be both configured via config and provided by event
  def foreign_stack?
    if identity.stack_id
      my_stack_id = swf_config["stack_id"]
      my_stack_id && identity.stack_id != my_stack_id
    end
  end

  def event
    @event ||= current_last_event_of_execution
  end

  def current_last_event_of_execution
    execution.history_events.reverse_order.first
  end

  def identity
    @identity ||= Identity.for(event)
  end

  def log_zombie
    message = "[#{Time.now}] Zombie"\
        " | app: #{app_name}"\
        " | type: #{event_type}"\
        " | execution: Rails.application.workflow.ntswf.domain.workflow_executions.at"\
        "(\"#{execution.workflow_id}\", \"#{execution.run_id}\")"\
        " | details: #{first_event_attributes.to_h}"
    File.open(File.expand_path("~/swf_tasks.log"), "a") do |f|
      f.puts message
    end
  end
end

class SwfTasks < Scout::Plugin
  needs 'aws-sdk'
  needs 'yaml'
  needs 'json'

  def swf_config
    @swf_config ||= YAML.load_file("/home/scout/swf_tasks.yml")
  end

  def metric_key(name, app_or_event)
    app =
        case app_or_event
        when String
          app_or_event
        else
          app_or_event.app_name
        end
    "#{app}_#{name}_tasks"
  end

  def swf_domain
    domain = AWS::SimpleWorkflow.new({
      :access_key_id => swf_config["simple_workflow_access_key_id"],
      :secret_access_key => swf_config["simple_workflow_secret_access_key"],
      :simple_workflow_endpoint => swf_config["simple_workflow_endpoint"],
      :use_ssl => true,
    }).domains[swf_config["simple_workflow_domain"]]
  end

  def open_executions
    swf_domain.workflow_executions.with_status(:open)
  end

  def statistics
    @statistics ||= begin
      statistics = Hash.new(0)
      %w[waiting zombie].each do |type|
        UNIT_PATTERN_TO_APP.values.each do |app|
          statistics[metric_key(type, app)] = 0
        end
      end
      statistics
    end
  end

  def build_report
    open_executions.each do |execution|
      last_event = LastEvent.new(execution, swf_config)
      case last_event.event_type
      when "ActivityTaskScheduled"
        statistics[metric_key("waiting", last_event)] += 1
      when "ActivityTaskStarted", "DecisionTaskStarted"
        if last_event.zombie?
          statistics[metric_key("zombie", last_event)] += 1
        end
      end
    end
    report(statistics)
  end
end
