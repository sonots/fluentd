#
# Fluentd
#
#    Licensed under the Apache License, Version 2.0 (the "License");
#    you may not use this file except in compliance with the License.
#    You may obtain a copy of the License at
#
#        http://www.apache.org/licenses/LICENSE-2.0
#
#    Unless required by applicable law or agreed to in writing, software
#    distributed under the License is distributed on an "AS IS" BASIS,
#    WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
#    See the License for the specific language governing permissions and
#    limitations under the License.
#

require 'ostruct'

module Fluent
  class RecordTransformerFilter < Filter
    Fluent::Plugin.register_filter('record_transformer', self)

    def initialize
      require 'socket'
      super
    end

    desc 'A comma-delimited list of keys to delete.'
    config_param :remove_keys, :string, :default => nil
    desc 'A comma-delimited list of keys to keep.'
    config_param :keep_keys, :string, :default => nil
    desc 'Create new Hash to transform incoming data'
    config_param :renew_record, :bool, :default => false
    desc 'Specify field name of the record to overwrite the time of events. Its value must be unix time.'
    config_param :renew_time_key, :string, :default => nil
    desc 'When set to true, the full Ruby syntax is enabled in the ${...} expression.'
    config_param :enable_ruby, :bool, :default => false
    desc 'Use original value type.'
    config_param :auto_typecast, :bool, :default => false # false for lower version compatibility

    def configure(conf)
      super

      map = {}
      # <record></record> directive
      conf.elements.select { |element| element.name == 'record' }.each do |element|
        element.each_pair do |k, v|
          element.has_key?(k) # to suppress unread configuration warning
          map[k] = parse_value(v)
        end
      end

      if @remove_keys
        @remove_keys = @remove_keys.split(',')
      end

      if @keep_keys
        raise Fluent::ConfigError, "`renew_record` must be true to use `keep_keys`" unless @renew_record
        @keep_keys = @keep_keys.split(',')
      end

      placeholder_expander_params = {
        :log           => log,
        :auto_typecast => @auto_typecast,
      }
      @placeholder_expander =
        if @enable_ruby
          # require utilities which would be used in ruby placeholders
          require 'pathname'
          require 'uri'
          require 'cgi'
          RubyPlaceholderExpander.new(placeholder_expander_params)
        else
          PlaceholderExpander.new(placeholder_expander_params)
        end
      @map = @placeholder_expander.preprocess_map(map)

      @hostname = Socket.gethostname
    end

    def filter_stream(tag, es)
      new_es = MultiEventStream.new
      tag_parts = tag.split('.')
      tag_prefix = tag_prefix(tag_parts)
      tag_suffix = tag_suffix(tag_parts)
      placeholder_values = {
        'tag'        => tag,
        'tag_parts'  => tag_parts,
        'tag_prefix' => tag_prefix,
        'tag_suffix' => tag_suffix,
        'hostname'   => @hostname,
      }
      last_record = nil
      es.each do |time, record|
        last_record = record # for debug log
        placeholder_values.merge!({
          'time'     => @placeholder_expander.time_value(time),
          'record'   => record,
        })
        new_record = reform(record, placeholder_values)
        if @renew_time_key && new_record.has_key?(@renew_time_key)
          time = EventTime.from_time(Time.at(new_record[@renew_time_key].to_f))
        end
        new_es.add(time, new_record)
      end
      new_es
    rescue => e
      log.warn "failed to reform records", :error_class => e.class, :error => e.message
      log.warn_backtrace
      log.debug "map:#{@map} record:#{last_record} placeholder_values:#{placeholder_values}"
    end

    private

    def parse_value(value_str)
      if value_str.start_with?('{', '[')
        JSON.parse(value_str)
      else
        value_str
      end
    rescue => e
      log.warn "failed to parse #{value_str} as json. Assuming #{value_str} is a string", :error_class => e.class, :error => e.message
      value_str # emit as string
    end

    def reform(record, placeholder_values)
      @placeholder_expander.prepare_placeholders(placeholder_values)

      new_record = @renew_record ? {} : record.dup
      @keep_keys.each {|k| new_record[k] = record[k]} if @keep_keys and @renew_record
      new_record.merge!(expand_placeholders(@map))
      @remove_keys.each {|k| new_record.delete(k) } if @remove_keys

      new_record
    end

    def expand_placeholders(value)
      if value.is_a?(String)
        new_value = @placeholder_expander.expand(value)
      elsif value.is_a?(Hash)
        new_value = {}
        value.each_pair do |k, v|
          new_value[@placeholder_expander.expand(k, true)] = expand_placeholders(v)
        end
      elsif value.is_a?(Array)
        new_value = []
        value.each_with_index do |v, i|
          new_value[i] = expand_placeholders(v)
        end
      else
        new_value = value
      end
      new_value
    end

    def tag_prefix(tag_parts)
      return [] if tag_parts.empty?
      tag_prefix = [tag_parts.first]
      1.upto(tag_parts.size-1).each do |i|
        tag_prefix[i] = "#{tag_prefix[i-1]}.#{tag_parts[i]}"
      end
      tag_prefix
    end

    def tag_suffix(tag_parts)
      return [] if tag_parts.empty?
      rev_tag_parts = tag_parts.reverse
      rev_tag_suffix = [rev_tag_parts.first]
      1.upto(tag_parts.size-1).each do |i|
        rev_tag_suffix[i] = "#{rev_tag_parts[i]}.#{rev_tag_suffix[i-1]}"
      end
      rev_tag_suffix.reverse!
    end

    class PlaceholderExpander
      attr_reader :placeholders, :log

      def initialize(params)
        @log = params[:log]
        @auto_typecast = params[:auto_typecast]
      end

      def time_value(time)
        Time.at(time).to_s
      end

      # Preprocess record map to convert into internal expression
      #
      # @param [Hash|String|Array] value record map config
      # @param [Boolean] force_stringify the value must be string, used for hash key
      def preprocess_map(value, force_stringify = false)
        new_value = nil
        if value.is_a?(String)
          if @auto_typecast and !force_stringify
            if single_placeholder_matched = value.match(/\A\${([^}]+)}\z/) # ${..} => ..
              new_value = [:single, single_placeholder_matched[1]]
            end
          end
          unless new_value
            new_value = %Q{%Q[#{value.gsub(/\$\{([^}]+)\}/, '#{\1}')}]} # xx${..}xx => %Q[xx#{..}xx]
          end
        elsif value.is_a?(Hash)
          new_value = {}
          value.each_pair do |k, v|
            new_value[preprocess_map(k, true)] = preprocess_map(v)
          end
        elsif value.is_a?(Array)
          new_value = []
          value.each_with_index do |v, i|
            new_value[i] = preprocess_map(v)
          end
        else
          new_value = value
        end
        new_value
      end

      def prepare_es_placehodlers(placeholder_values)
        @es_placeholders = _prepare_placeholders(placeholder_values)
      end

      def prepare_event_placehodlers(placeholder_values)
        event_placeholders = _prepare_placeholders(placeholder_values)
        @placeholders = @es_placeholders.merge(event_placeholders)
      end

      def _prepare_placeholders(placeholder_values)
        placeholders = {}

        placeholder_values.each do |key, value|
          if value.kind_of?(Array) # tag_parts, etc
            size = value.size
            value.each_with_index do |v, idx|
              placeholders.store("${#{key}[#{idx}]}", v)
              placeholders.store("${#{key}[#{idx-size}]}", v) # support [-1]
            end
          elsif value.kind_of?(Hash) # record, etc
            value.each do |k, v|
              placeholders.store("${#{k}}", v) # foo
              placeholders.store(%Q[${#{key}["#{k}"]}], v) # record["foo"]
            end
          else # string, interger, float, and others?
            placeholders.store("${#{key}}", value)
          end
        end

        placeholders
      end

      # Expand string with placeholders
      #
      # @param [String] str
      # @param [Boolean] force_stringify the value must be string, used for hash key
      def expand(str, force_stringify = false)
        if @auto_typecast and !force_stringify
          single_placeholder_matched = str.match(/\A(\${[^}]+}|__[A-Z_]+__)\z/)
          if single_placeholder_matched
            log_if_unknown_placeholder($1)
            return @placeholders[single_placeholder_matched[1]]
          end
        end
        str.gsub(/(\${[^}]+}|__[A-Z_]+__)/) {
          log_if_unknown_placeholder($1)
          @placeholders[$1]
        }
      end

      private

      def log_if_unknown_placeholder(placeholder)
        unless @placeholders.include?(placeholder)
          log.warn "unknown placeholder `#{placeholder}` found"
        end
      end
    end

    class RubyPlaceholderExpander
      attr_reader :log

      def initialize(params)
        @log = params[:log]
        @auto_typecast = params[:auto_typecast]
        @cleanroom_expander = CleanroomExpander.new
      end

      def time_value(time)
        Time.at(time)
      end

      # Preprocess record map to convert into ruby string expansion
      #
      # @param [Hash|String|Array] value record map config
      # @param [Boolean] force_stringify the value must be string, used for hash key
      def preprocess_map(value, force_stringify = false)
        new_value = nil
        if value.is_a?(String)
          if @auto_typecast and !force_stringify
            if single_placeholder_matched = value.match(/\A\${([^}]+)}\z/) # ${..} => ..
              new_value = single_placeholder_matched[1]
            end
          end
          unless new_value
            new_value = %Q{%Q[#{value.gsub(/\$\{([^}]+)\}/, '#{\1}')}]} # xx${..}xx => %Q[xx#{..}xx]
          end
        elsif value.is_a?(Hash)
          new_value = {}
          value.each_pair do |k, v|
            new_value[preprocess_map(k, true)] = preprocess_map(v)
          end
        elsif value.is_a?(Array)
          new_value = []
          value.each_with_index do |v, i|
            new_value[i] = preprocess_map(v)
          end
        else
          new_value = value
        end
        new_value
      end

      def prepare_placeholders(placeholder_values)
        @tag = placeholder_values['tag']
        @time = placeholder_values['time']
        @record = placeholder_values['record']
        @tag_parts = placeholder_values['tag_parts']
        @tag_prefix = placeholder_values['tag_prefix']
        @tag_suffix = placeholder_values['tag_suffix']
        @hostname = placeholder_values['hostname']
      end

      # Expand string with placeholders
      #
      # @param [String] str
      def expand(str, force_stringify = false)
        @cleanroom_expander.expand(
          str,
          @tag,
          @time,
          @record,
          @tag_parts,
          @tag_prefix,
          @tag_suffix,
          @hostname,
        )
      rescue => e
        log.warn "failed to expand `#{str}`", :error_class => e.class, :error => e.message
        log.warn_backtrace
        nil
      end

      class CleanroomExpander
        def expand(__str_to_eval__, tag, time, record, tag_parts, tag_prefix, tag_suffix, hostname)
          tags = tag_parts # for old version compatibility
          @record = record # for old version compatibility
          instance_eval(__str_to_eval__)
        end

        # for old version compatibility
        def method_missing(name)
          key = name.to_s
          if @record.has_key?(key)
            @record[key]
          else
            raise NameError, "undefined local variable or method `#{key}'"
          end
        end

        (Object.instance_methods).each do |m|
          undef_method m unless m.to_s =~ /^__|respond_to_missing\?|object_id|public_methods|instance_eval|method_missing|define_singleton_method|respond_to\?|new_ostruct_member/
        end
      end
    end
  end
end
