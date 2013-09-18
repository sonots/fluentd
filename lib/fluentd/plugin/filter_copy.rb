#
# Fluentd
#
# Copyright (C) 2011-2012 FURUHASHI Sadayuki
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
require 'fluentd/plugin/filter'

module Fluentd
  module Plugin

    class CopyFilter < Filter
      Plugin.register_filter('copy', self)

      config_param :deep_copy, :bool, :default => false

      def configure(conf)
        super
      end

      def emit(tag, time, record)
        if @deep_copy
          collector.emit(tag, time, record)
        else
          collector.emit(tag, time, record.dup)
        end
      end

      def emits(tag, es)
        if @deep_copy
          collector.emits(tag, es)
        else
          collector.emits(tag, es.dup)
        end
      end
    end

  end
end

