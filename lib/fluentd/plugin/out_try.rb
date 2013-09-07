module Fluentd
  module Plugin
    class TryOutput < Output
      Plugin.register_output('try', self)

      config_param :try_string, :string, :default => 'foo'
      config_param :try_integer, :integer, :default => 0
      config_param :try_float, :float, :default => 0.0
      config_param :try_size, :size, :default => 1
      config_param :try_bool, :bool, :default => true
      config_param :try_time, :time, :default => 10
      config_param :try_hash, :hash, :default => {foo: 'bar'}
      config_param :try_any, :any, :default => ['foo','bar']

      def configure(conf)
        super
        $stdout.write "out_try: string #{@try_string}\n"
        $stdout.write "out_try: interger #{@try_integer}\n"
        $stdout.write "out_try: float #{@try_float}\n"
        $stdout.write "out_try: size #{@try_size}\n"
        $stdout.write "out_try: bool #{@try_bool}\n"
        $stdout.write "out_try: time #{@try_time}\n"
        $stdout.write "out_try: hash #{@try_hash}\n"
        $stdout.write "out_try: any #{@try_any}\n"
      end
    end

  end
end
