# Fluentd ソースコード完全解説
英題：Fluentd Hacking Guide

# 目次

30分しかないため斜線部分は今回省く

* Fluentd の起動シーケンスとプラグインの読み込み
* ~~Fluentd の設定ファイルのパース~~
* Input Plugin から Output Plugin にデータが渡る流れ
* BufferedOutput プラグイン
* ~~Cool.io を用いたイベント駆動開発と、GVL~~
* ~~Cool.io コードリーディング~~

# Internal Links

* [Fluentd の起動シーケンスとプラグインの読み込み](#fluentd-%E3%81%AE%E8%B5%B7%E5%8B%95%E3%82%B7%E3%83%BC%E3%82%B1%E3%83%B3%E3%82%B9%E3%81%A8%E3%83%97%E3%83%A9%E3%82%B0%E3%82%A4%E3%83%B3%E3%81%AE%E8%AA%AD%E3%81%BF%E8%BE%BC%E3%81%BF)
  * [Fluent::Config#parse](#fluent::config%23parse)
  * [Fluent::Engine#run_configure](#fluent::engine%23run_configure)
  * [Fluent::Engine#run](#fluent::engine%23run)
* [Input Plugin から Output Plugin にデータが渡る流れ](#input-plugin-%E3%81%8B%E3%82%89-output-plugin-%E3%81%AB%E3%83%87%E3%83%BC%E3%82%BF%E3%81%8C%E6%B8%A1%E3%82%8B%E6%B5%81%E3%82%8C)
  * [Input から Output を通した流れまとめ](#input-%E3%81%8B%E3%82%89-output-%E3%82%92%E9%80%9A%E3%81%97%E3%81%9F%E6%B5%81%E3%82%8C%E3%81%BE%E3%81%A8%E3%82%81)
  * [大事な補足](#%E5%A4%A7%E4%BA%8B%E3%81%AA%E8%A3%9C%E8%B6%B3)
* [BufferedOutput プラグイン](#bufferedoutput-%E3%83%97%E3%83%A9%E3%82%B0%E3%82%A4%E3%83%B3)
  * [BufferedOutput の構造](#bufferedoutput-%E3%81%AE%E6%A7%8B%E9%80%A0)
  * [メソッド一覧](#%E3%83%A1%E3%82%BD%E3%83%83%E3%83%89%E4%B8%80%E8%A6%A7)
  * [BufferedOutput のスレッド状態](#bufferedoutput-%E3%81%AE%E3%82%B9%E3%83%AC%E3%83%83%E3%83%89%E7%8A%B6%E6%85%8B)
  * [データ送信の流れ](#%E3%83%87%E3%83%BC%E3%82%BF%E9%80%81%E4%BF%A1%E3%81%AE%E6%B5%81%E3%82%8C)
  * [まとめおよび補足](#%E3%81%BE%E3%81%A8%E3%82%81%E3%81%8A%E3%82%88%E3%81%B3%E8%A3%9C%E8%B6%B3)
* [まとめ](#%E3%81%BE%E3%81%A8%E3%82%81)

# Fluentd の起動シーケンスとプラグインの読み込み

[bin/fluentd#L6](https://github.com/fluent/fluentd/blob/b5dca056378257820c3ce675fa04e34d94349fa9/bin/fluentd)

fluentd コマンドを実行すると `lib/fluent/command/fluentd` が require される

```ruby
#!/usr/bin/env ruby
require 'rubygems' unless defined?(gem)
here = File.dirname(__FILE__)
$LOAD_PATH << File.expand_path(File.join(here, '..', 'lib'))
require 'fluent/command/fluentd'
```

[lib/fluent/command/fluentd.rb#L160](https://github.com/fluent/fluentd/blob/b5dca056378257820c3ce675fa04e34d94349fa9/lib/fluent/command/fluentd.rb#L160)

各種オプション処理をされた後、`Fluent::Supervisor#start` が呼び出される。

```ruby
Fluent::Supervisor.new(opts).start
```

[Fluent::Supervisor#start](https://github.com/fluent/fluentd/blob/b5dca056378257820c3ce675fa04e34d94349fa9/lib/fluent/supervisor.rb#L121-L140)

Fluent::Supervisor は daemon 起動を司るクラス。ここが起動シーケンスのメイン。

ここで、デーモン化の処理、シグナルハンドラ(kill -USR1 を受け取った場合の処理など)の登録、
fluentd の config ファイルの読み込み、プラグインの読み込み、プラグインの起動などを行う。

ここでプラグイン読み込みに関して着目すべきは
`#run_configure` の中身である `Fluent::Engine#parse_config`と
`#run_engine` の中身である `Fluent::Engine#run` なのでそこを深掘りしていく。

```ruby
    def start
      require 'fluent/load'
      @log.init

      dry_run if @dry_run
      start_daemonize if @daemonize
      install_supervisor_signal_handlers
      until @finished
        supervise do
          read_config
          change_privilege
          init_engine
          install_main_process_signal_handlers
          run_configure
          finish_daemonize if @daemonize
          run_engine
          exit 0
        end
        $log.error "fluentd main process died unexpectedly. restarting." unless @finished
      end
    end

    ...

    def run_configure
      conf = Fluent::Config.parse(@config_data, @config_fname, @config_basedir, @use_v1_config)
      Fluent::Engine.run_configure(conf)
    end

    ...

    def run_engine
      Fluent::Engine.run
    end
```

## Fluent::Config#parse

[Fluent::Config#parse](https://github.com/fluent/fluentd/blob/b5dca056378257820c3ce675fa04e34d94349fa9/lib/fluent/config.rb#L23-L36)

Fluentd の conf ファイルを parse している。
現在、ruby dsl, v1, 通常の３モード持っているのでそれぞれで違う Parser を使っている。
今回は深く追わない。

```ruby
    def self.parse(str, fname, basepath = Dir.pwd, v1_config = false)
      if fname =~ /\.rb$/
        require 'fluent/config/dsl'
        Config::DSL::Parser.parse(str, File.join(basepath, fname))
      else
        if v1_config
          require 'fluent/config/v1_parser'
          V1Parser.parse(str, fname, basepath, Kernel.binding)
        else
          require 'fluent/config/parser'
          Parser.parse(str, fname, basepath)
        end
      end
    end
```

## Fluent::Engine#run_configure

[Fluent::Engine#run_configure](https://github.com/fluent/fluentd/blob/b5dca056378257820c3ce675fa04e34d94349fa9/lib/fluent/engine.rb#L76-L132)

ここでプラグインのロード、new、configure 呼び出しが行われる

1. conf ファイルの source ディレクティブを読み込んで、Input プラグインを new し、configure メソッドを呼び出している
1. 同様に match ディレクティブを読み込んで、Output プラグインを new し、configure メソッドを呼び出している

```ruby
    def run_configure(conf)
      configure(conf)
      conf.check_not_fetched { |key, e|
        unless e.name == 'system'
          unless @without_source && e.name == 'source'
            $log.warn "parameter '#{key}' in #{e.to_s.strip} is not used."
          end
        end
      }
    end

    def configure(conf)
      # plugins / configuration dumps
      Gem::Specification.find_all.select{|x| x.name =~ /^fluent(d|-(plugin|mixin)-.*)$/}.each do |spec|
        $log.info "gem '#{spec.name}' version '#{spec.version}'"
      end

      unless @suppress_config_dump
        $log.info "using configuration file: #{conf.to_s.rstrip}"
      end

      if @without_source
        $log.info "'--without-source' is applied. Ignore <source> sections"
      else
        conf.elements.select {|e|
          e.name == 'source'
        }.each {|e|
          type = e['type']
          unless type
            raise ConfigError, "Missing 'type' parameter on <source> directive"
          end
          $log.info "adding source type=#{type.dump}"

          # ここでプラグインの require と new 呼び出しがされる
          input = Plugin.new_input(type)
          # 直後に configure メソッドが呼び出される
          input.configure(e)

          @sources << input
        }
      end

      conf.elements.select {|e|
        e.name == 'match'
      }.each {|e|
        type = e['type']
        pattern = e.arg
        unless type
          raise ConfigError, "Missing 'type' parameter on <match #{e.arg}> directive"
        end
        $log.info "adding match", :pattern=>pattern, :type=>type

        # ここでプラグインの require と new 呼び出しがされる
        output = Plugin.new_output(type)
        # 直後に configure メソッドが呼び出される
        output.configure(e)

        match = Match.new(pattern, output)
        @matches << match
      }
    end
```

[lib/fluent/plugin.rb#L76-L141](https://github.com/fluent/fluentd/blob/b5dca056378257820c3ce675fa04e34d94349fa9/lib/fluent/plugin.rb#L76-141)

`try＿load_plugin` で、プラグインディレクトリにファイルがあれば、それを require し、
なければ gem を検索して require している。

見つかれば new し、なければエラーとなる。

```ruby
    # type はプラグイン名。config の type 句
    def new_input(type)
      new_impl('input', @input, type)
    end
    ...
    def new_impl(name, map, type)
      if klass = map[type]
        return klass.new
      end
      try_load_plugin(name, type)
      # map には、プラグイン内の register_input メソッドの呼びだしによって登録される
      if klass = map[type]
        return klass.new
      end
      raise ConfigError, "Unknown #{name} plugin '#{type}'. Run 'gem search -rd fluent-plugin' to find plugins"
    end

    def try_load_plugin(name, type)
      case name
      when 'input'
        path = "fluent/plugin/in_#{type}"
      when 'output'
        path = "fluent/plugin/out_#{type}"
      when 'buffer'
        path = "fluent/plugin/buf_#{type}"
      else
        return
      end

      # prefer LOAD_PATH than gems
      files = $LOAD_PATH.map {|lp|
        lpath = File.join(lp, "#{path}.rb")
        File.exist?(lpath) ? lpath : nil
      }.compact
      unless files.empty?
        # prefer newer version
        require File.expand_path(files.sort.last)
        return
      end

      # search gems
      if defined?(::Gem::Specification) && ::Gem::Specification.respond_to?(:find_all)
        specs = Gem::Specification.find_all {|spec|
          spec.contains_requirable_file? path
        }

        # prefer newer version
        specs = specs.sort_by {|spec| spec.version }
        if spec = specs.last
          spec.require_paths.each {|lib|
            file = "#{spec.full_gem_path}/#{lib}/#{path}"
            require file
          }
        end

        # backward compatibility for rubygems < 1.8
      elsif defined?(::Gem) && ::Gem.respond_to?(:searcher)
        # こっちは省略
      end
    end
```

## Fluent::Engine#run

[Fluent::Engine#run](https://github.com/fluent/fluentd/blob/b5dca056378257820c3ce675fa04e34d94349fa9/lib/fluent/engine.rb#L211-L244)

Input、Output のタイプに関わらず、プラグインの start メソッドが呼ばれる。

ここで、Input プラグインの場合は、起動したスレッドでデータを読む込む
(ソケット待ち受けや、I/O待ち受けのような)コードを書くことにより、
Input プラグインにデータが流れてくるようになる。

Output プラグインの場合は、ここでは通常、初期化処理のみを行う。

なお、Ctrl-C など stop 要請があったら、プラグインの shutdown メソッドが呼ばれるので、
通常スレッドを閉じるなどの後処理を行う。

```ruby
    def run
      begin
        start

        if match?($log.tag)
          $log.enable_event
          @log_emit_thread = Thread.new(&method(:log_event_loop))
        end

        unless @engine_stopped
          # for empty loop
          @default_loop = Coolio::Loop.default
          @default_loop.attach Coolio::TimerWatcher.new(1, true)
          #  attach async watch for thread pool
          @default_loop.run
        end

        if @engine_stopped and @default_loop
          @default_loop.stop
          @default_loop = nil
        end

      rescue => e
        $log.error "unexpected error", :error_class=>e.class, :error=>e
        $log.error_backtrace
      ensure
        $log.info "shutting down fluentd"
        shutdown
        if @log_emit_thread
          @log_event_loop_stop = true
          @log_emit_thread.join
        end
      end
    end

    ...

    def start
      @matches.each {|m|
        m.start
        @started_matches << m
      }
      @sources.each {|s|
        s.start
        @started_sources << s
      }
    end

    ...

    def shutdown
      # Shutdown Input plugin first to prevent emitting to terminated Output plugin
      @started_sources.map { |s|
        Thread.new do
          begin
            s.shutdown
          rescue => e
            $log.warn "unexpected error while shutting down", :plugin => s.class, :plugin_id => s.plugin_id, :error_class => e.class, :error => e
            $log.warn_backtrace
          end
        end
      }.each { |t|
        t.join
      }
      # Output plugin as filter emits records at shutdown so emit problem still exist.
      # This problem will be resolved after actual filter mechanizm.
      @started_matches.map { |m|
        Thread.new do
          begin
            m.shutdown
          rescue => e
            $log.warn "unexpected error while shutting down", :plugin => m.output.class, :plugin_id => m.output.plugin_id, :error_class => e.class, :error => e
            $log.warn_backtrace
          end
        end
      }.each { |t|
        t.join
      }
    end
```

# Input Plugin から Output Plugin にデータが渡る流れ

Input プラグイン(または Output プラグイン) 内の実装で、
Engine#emit を呼び出すと、tag がマッチする <match **> 節に指定した
Output プラグインの #emit メソッドが呼び出される。

[lib/fluent/engine.rb#L138-L171](https://github.com/fluent/fluentd/blob/b5dca056378257820c3ce675fa04e34d94349fa9/lib/fluent/engine.rb#L138-L171)

`emit` メソッドから `emit_stream` が呼び出され、
`emit_stream` で match(tag) オブジェクト、
つまり output プラグインのインスタンス、の emit メソッドを呼び出し、
データが流れることになる。


```ruby
    def emit(tag, time, record)
      unless record.nil?
        emit_stream tag, OneEventStream.new(time, record)
      end
    end

    def emit_array(tag, array)
      emit_stream tag, ArrayEventStream.new(array)
    end

    def emit_stream(tag, es)
      target = @match_cache[tag]
      unless target
        target = match(tag) || NoMatchMatch.new
        # this is not thread-safe but inconsistency doesn't
        # cause serious problems while locking causes.
        if @match_cache_keys.size >= MATCH_CACHE_SIZE
          @match_cache.delete @match_cache_keys.shift
        end
        @match_cache[tag] = target
        @match_cache_keys << tag
      end
      target.emit(tag, es)
    rescue => e
      if @suppress_emit_error_log_interval == 0 || now > @next_emit_error_log_time
        $log.warn "emit transaction failed ", :error_class=>e.class, :error=>e
        $log.warn_backtrace
        # $log.debug "current next_emit_error_log_time: #{Time.at(@next_emit_error_log_time)}"
        @next_emit_error_log_time = Time.now.to_i + @suppress_emit_error_log_interval
        # $log.debug "next emit failure log suppressed"
        # $log.debug "next logged time is #{Time.at(@next_emit_error_log_time)}"
      end
      raise
    end
```

## Input から Output を通した流れまとめ

起動時

1. config に登場する全プラグインをインスタンス化
2. 全プラグイン#configure
3. 全プラグイン#start。ここで通常 Input プラグインはスレッド(Coolio)を切る。

Input

1. Input プラグインのイベントループが入力を受け付ける
2. Input プラグインが、Engine.emit を呼び出す
3. Fluentd 本体が tag に match する output プラグインを見つけて output#emit を呼び出す

Output

1. output#emit が呼ばれる
2. HTTP ポストするなど Output プラグインの処理を行う。
3. 別の Output プラグインを Engine#emit から呼び出している場合は、そちらの output プラグインの #emit 処理に入る。

## 大事な補足

よくある流れの例としては次のシーケンス図のようになる。

```
+----------+  +-------------+  +------------+  +------------+
|  Input   |  |  Output1    |  |  Output2   |  |  Output3   |
+----+-----+  +------+------+  +-----+------+  +-----+------+
     |  ex) in_tail  | ex) parser    | ex) grep      | ex) out_growthforecast
     |               |               |               |
     |   #emit       |               |               |
     +--------------->    #emit      |               |
     |               +--------------->    #emit      |
     |               |               +--------------->
     |               |               |               |
     |               |               <- - - - - - - -+
     |               <- - - - - - - -+               |
     <- - - - - - - -+               |               |
     |               |               |               |
```

ここで気づかなければならない点は、
Output1, Output2, Output3 プラグイン全ての処理が終わらないと、
Input プラグインの次の入力受付の処理に戻れないという点である。

これを避けるために Output プラグインでブロックさせたくない場合は、
Output プラグインを BufferedOuput プラグインに すると、#emit
呼び出しでは enqueue するだけにして、
別スレッドで実際の処理をしてくれるようになるのでご利用いただける。

なお、このブロックしている時間を計測、可視化するためのツールとして、
[fluent-plugin-measure_time](https://github.com/sonots/fluent-plugin-measure_time) を作成しているのでご利用いただける。


# BufferedOutput プラグイン

BufferedOuput プラグインにすると、#emit
呼び出しでは enqueue するだけにして、
別スレッドで実際の処理をすることができるようになる。
Output プラグインのようにブロックしない

## BufferedOutput の構造

```
+-------------------+       1.* +---------------+
|  BufferedOutput   | --------> | OutputThread  |
+-------------------+           +---------------+
| - writers         |
| - buffer          |         1 +---------------------+
+-------------------+ --------> | (Memory|File)Buffer |
+-------------------+           +---------------------+
     △                                  ｜
     ｜                                  ▽
+------------------------+      +---------------+
|  ObjectBufferedOutput  |      | BasicBuffer   |
+------------------------+      +---------------+
```

## メソッド一覧

### BufferedOutput のメソッド

[BufferedOutput](https://github.com/fluent/fluentd/blob/b5dca056378257820c3ce675fa04e34d94349fa9/lib/fluent/output.rb#L162-L414)

```ruby
  class BufferedOutput < Output
    def initialize # new
    def configure(conf) # オプション処理
    def start # スレッドスタート
    def shutdown # スレッドストップ
    def emit(tag, es, chain, key="") # Fluentd本体からデータを送られるエンドポイント
    def submit_flush #すぐ try_flush が呼ばれるように時間フラグを0にリセット
    def format_stream(tag, es) # データ stream のシリアライズ
    #def format(tag, time, record) # format_stream が呼び出す。単データのシリアライズをここで定義する
    #def write(chunk) # Buffer スレッドがこのメソッドを呼び出す
    def enqueue_buffer # Buffer キューにデータを追加
    def try_flush # Buffer キューからデータを取り出して flush する。flush 処理は別スレッドで実行される。@buffer.pop を呼び出す。
    def force_flush # USR1 シグナルを受けた時に強制 flush する
    def before_shutdown # shutdown 前処理
    def calc_retry_wait # retry 時間間隔の計算(exponential backoff)
    def write_abort # retry 限界を超えた場合に buffer を捨てる
    def flush_secondary(secondary) # secondary ノードへの flush
  end
```

ForwardOutput なんかは実際には [ObjectBufferedOutput](https://github.com/fluent/fluentd/blob/b5dca056378257820c3ce675fa04e34d94349fa9/lib/fluent/output.rb#L417-L451)
を継承している。

```ruby
  class ObjectBufferedOutput < BufferedOutput
    def initialize
    def emit(tag, es, chain) # msgpack にシリアライズするようにオーバーライド
    def write(chunk) # msgpack にシリアライズするようにオーバーライド. write_objects(chunk.key, chunk) を呼び出す
  end
```


### OutputThread のメソッド

[OutputThread](https://github.com/fluent/fluentd/blob/b5dca056378257820c3ce675fa04e34d94349fa9/lib/fluent/output.rb#L89-L159)

```ruby
  # num_threads で output プラグインの並列数を増やすために利用
  class OutputThread
    def initialize(output) # output プラグイン自身を渡す
    def configure(conf)
    def start # スレッドスタート
    def shutdown # スレッド終了
    def submit_flush #すぐ try_flush が呼ばれるように時間フラグを0にリセット
    private
    def run # スレッドループ。時間がきたら try_flush を呼ぶ
    def cond_wait(sec) # ConditionVariable を使って sec 秒待つ
  end
```

### BasicBuffer のメソッド

[BasicBuffer](https://github.com/fluent/fluentd/blob/b5dca056378257820c3ce675fa04e34d94349fa9/lib/fluent/buffer.rb#L116-L305)

```ruby
  class BasicBuffer < Buffer
    def initialize
    def enable_parallel(b=true)
    config_param :buffer_chunk_limit, :size, :default => 8*1024*1024
    config_param :buffer_queue_limit, :integer, :default => 256
    def configure(conf) # プラグインオプション設定
    def start # buffer plugin の start
    def shutdown # buffer plugin の shutdown
    def storable?(chunk, data) # buffer_chunk_limit を超えていないかどうか
    def emit(key, data, chain) # Fluentd本体からデータを送られるエンドポイント
    def keys # 取り扱っている key (基本的には tag) 一覧
    def queue_size # queue のサイズ
    def total_queued_chunk_size # キューに入っている全 chunk のサイズ
    #def new_chunk(key) # 扱う chunk オブジェクトの定義をすること
    #def resume # queue, map の初期化定義をすること
    #def enqueue(chunk) # chunk の enqueue を定義すること
    def push(key) # BufferedOutput が try_flush する時に呼び出されるようだ
    def pop(out) # queue から chunk を取り出して write_chunk する
    def write_chunk(chunk, out) # 中身は out.write(chunk)
    def clear! # queue をクリアする
  end
```

MemoryBuffer [buf_memory.rb#L67-L102](https://github.com/fluent/fluentd/blob/b5dca056378257820c3ce675fa04e34d94349fa9/lib/fluent/plugin/buf_memory.rb#L67-L102)

```ruby
  class MemoryBuffer < BasicBuffer
    def initialize
    def configure(conf)
    def before_shutdown(out)
    def new_chunk(key) # MemoryBufferChunk.new(key)
    def resume # @queue, @map = [], {}
    def enqueue(chunk) # 空
  end
```

## BufferedOutput のスレッド状態

num_threads 数の OutputThread スレッドが立ち上がる

```ruby
  class BufferedOutput < Output
    ...
    config_param :buffer_type, :string, :default => 'memory'
    ...
    config_param :num_threads, :integer, :default => 1

    def configure(conf)
      super

      @buffer = Plugin.new_buffer(@buffer_type)
      @buffer.configure(conf)
      ...
      @writers = (1..@num_threads).map {
        writer = OutputThread.new(self)
        writer.configure(conf)
        writer
      }
      ...
    end

    def start
      @buffer.start # スレッド作らない
      ...
      @writers.each {|writer| writer.start } # スレッド作る
      ...
    end

    def shutdown
      @writers.each {|writer| writer.shutdown }
      @buffer.shutdown
    end
```

## データ送信の流れ

シーケンス図

Input プラグインのスレッド。データ入力があった。

```
+--------+     +----------------+     +-------------+
| Input  |     | BufferedOutput |     | BasicBuffer |
+----+---+     +--------+-------+     +------+------+
     |                  |                    |
     |  emit(tag, es)   |                    |
     | -------------->  |   emit(tag, data)   |
     |                  | -----------------> |
     |                  |                    | top (chunk) << data
     |                  |                    |
     |                  |                    | if top.size > buffer_chunk_limit
     |                  |                    |   @queue << top (chunk)
```

OutputThread のスレッド。時間がたった


```
+---------------+  +-----------------+  +--------------+
| OutputThread  |  | BufferedOutput  |  | BasicBuffer  |
+------+--------+  +--------+--------+  +------+-------+
       |                    |                  |
       |     try_flush      |                  |
       | -----------------> |     (push)       |
       |                    | ---------------> |
       |                    |                  | @queue << top (chunk)
       |                    |      pop         |
       |                    | ---------------> |
       |                    |                  |
       |                    |      write       |
       |                    | <--------------- |
       |                    |                  |
       |                    |   do something   |
       |                    | ------------------------>
```

### Input プラグインからデータを受け取る時の処理

Fluentd プラグインの仕組みが #emit を呼び出してデータを送って来る

[ObjectBufferedOutput#emit](https://github.com/fluent/fluentd/blob/b5dca056378257820c3ce675fa04e34d94349fa9/lib/fluent/output.rb#L417-L429)

```ruby
  class ObjectBufferedOutput < BufferedOutput
    ...

    def emit(tag, es, chain)
      @emit_count += 1
      data = es.to_msgpack_stream
      key = tag
      if @buffer.emit(key, data, chain)
        submit_flush
      end
    end
```

[BasicBuffer#emit](https://github.com/fluent/fluentd/blob/b5dca056378257820c3ce675fa04e34d94349fa9/lib/fluent/buffer.rb#L165-L214) @buffer.emit

*  top chunk が buffer_chunk_limit を超えてなければ chunk に data を格納
*  超えていれば次の処理
  * 入らなかったデータを next chunk に格納
  * top chunk を queue に格納
  * 次の top chunk を next chunk で更新

```ruby
    def start
      @queue, @map = resume
      @queue.extend(MonitorMixin)
    end

    def emit(key, data, chain)
      key = key.to_s

      synchronize do
        top = (@map[key] ||= new_chunk(key))  # TODO generate unique chunk id

        # top chunk が buffer_chunk_limit を超えてなければ chunk に data を格納
        if storable?(top, data)
          chain.next
          top << data
          return false

          ## FIXME
          #elsif data.bytesize > @buffer_chunk_limit
          #  # TODO
          #  raise BufferChunkLimitError, "received data too large"

        elsif @queue.size >= @buffer_queue_limit
          raise BufferQueueLimitError, "queue size exceeds limit"
        end

        if data.bytesize > @buffer_chunk_limit
          $log.warn "Size of the emitted data exceeds buffer_chunk_limit."
          $log.warn "This may occur problems in the output plugins ``at this server.``"
          $log.warn "To avoid problems, set a smaller number to the buffer_chunk_limit"
          $log.warn "in the forward output ``at the log forwarding server.``"
        end

        nc = new_chunk(key) # TODO generate unique chunk id
        ok = false

        begin
          nc << data # 入らなかった分を next chunk に格納
          chain.next

          flush_trigger = false
          @queue.synchronize {
            enqueue(top)
            flush_trigger = @queue.empty?
            @queue << top # top chunk を queue に格納
            @map[key] = nc # 次の top chunk を更新
          }

          ok = true
          return flush_trigger
        ensure
          nc.purge unless ok
        end

      end  # synchronize
    end
```

[MemoryBufferChunk](https://github.com/fluent/fluentd/blob/b5dca056378257820c3ce675fa04e34d94349fa9/lib/fluent/plugin/buf_memory.rb#L19-L64) new_chunk の実体

@buffer << data で、文字列として追記しているだけ

```ruby
  class MemoryBufferChunk < BufferChunk
    def initialize(key, data='')
      @data = data
      @data.force_encoding('ASCII-8BIT')
      now = Time.now.utc
      u1 = ((now.to_i*1000*1000+now.usec) << 12 | rand(0xfff))
      @unique_id = [u1 >> 32, u1 & u1 & 0xffffffff, rand(0xffffffff), rand(0xffffffff)].pack('NNNN')
      super(key)
    end

    attr_reader :unique_id

    def <<(data)
      data.force_encoding('ASCII-8BIT')
      @data << data # 文字列として追記しているだけ
    end

    def size
      @data.bytesize
    end

    def close
    end

    def purge
    end

    def read
      @data
    end

    def open(&block)
      StringIO.open(@data, &block)
    end

    # optimize
    def write_to(io)
      io.write @data
    end

    # optimize
    def msgpack_each(&block)
      u = MessagePack::Unpacker.new
      u.feed_each(@data, &block)
    end
  end
```

[MemoryBuffer](https://github.com/fluent/fluentd/blob/b5dca056378257820c3ce675fa04e34d94349fa9/lib/fluent/plugin/buf_memory.rb#L67-L102) @queue の実体, enqueue(chunk) の定義

メモリバッファの場合、@queue はただの配列で、@map もただのハッシュ。enqueue(chunk) でもとくに何もやっていない。
[FileBuffer](https://github.com/fluent/fluentd/blob/b5dca056378257820c3ce675fa04e34d94349fa9/lib/fluent/plugin/buf_file.rb#L76) の場合は色々やっているが、今回はカバーしない。

```ruby
  class MemoryBuffer < BasicBuffer
    Plugin.register_buffer('memory', self)

    def initialize
      super
    end

    # Overwrite default BasicBuffer#buffer_queue_limit
    # to limit total memory usage upto 512MB.
    config_set_default :buffer_queue_limit, 64

    def configure(conf)
      super
    end

    def before_shutdown(out)
      synchronize do
        @map.each_key {|key|
          push(key)
        }
        while pop(out)
        end
      end
    end

    def new_chunk(key)
      MemoryBufferChunk.new(key)
    end

    def resume
      return [], {} # @queue が [] で @map が {}
    end

    def enqueue(chunk)
      # なにもやってない
    end
  end
```

### OutputThread から try_flush を呼ばれたときの処理

[OutputThread](https://github.com/fluent/fluentd/blob/b5dca056378257820c3ce675fa04e34d94349fa9/lib/fluent/output.rb#L89-L159) では、run ループを別スレッドで回して、try_flush_interval 毎に output#try_flush を呼ぶ。

try_flush ではデータを queue から pop してデータ送信する。

つまり、データ送信を複数の別スレッドで並列に行っている。特に、対向 Fluentd プロセスが複数ある場合に有効。
１つの場合でも受信側が nonblocking でデータをうまく捌いてくれるような場合には有効になりえるだろう。

注意：try_flush_interval がデフォルトの 1 の場合、flush_interval 0s にしても 1 秒毎にしか flush されない。


```ruby
  class OutputThread
    def initialize(output)
      @output = output
      @finish = false
      @next_time = Engine.now + 1.0
    end

    def configure(conf)
    end

    def start
      @mutex = Mutex.new
      @cond = ConditionVariable.new
      @thread = Thread.new(&method(:run))
    end

    def shutdown
      @finish = true
      @mutex.synchronize {
        @cond.signal
      }
      Thread.pass
      @thread.join
    end

    def submit_flush
      @mutex.synchronize {
        @next_time = 0
        @cond.signal
      }
      Thread.pass
    end

    private
    def run
      @mutex.lock
      begin
        until @finish
          time = Engine.now

          if @next_time <= time
            @mutex.unlock
            begin
              @next_time = @output.try_flush
            ensure
              @mutex.lock
            end
            next_wait = @next_time - Engine.now
          else
            next_wait = @next_time - time
          end

          cond_wait(next_wait) if next_wait > 0
        end
      ensure
        @mutex.unlock
      end
    rescue
      $log.error "error on output thread", :error=>$!.to_s
      $log.error_backtrace
      raise
    ensure
      @mutex.synchronize {
        @output.before_shutdown
      }
    end

    def cond_wait(sec)
      @cond.wait(@mutex, sec)
    end
  end
```

前半のみ読む [output.rb#L271-L325](https://github.com/fluent/fluentd/blob/b5dca056378257820c3ce675fa04e34d94349fa9/lib/fluent/output.rb#L271-L325)

主要な流れをざっくり

* buffer_chunk_limit に達していなくても flush_interval が来たら enqueue する
* queue から chunk を pop して output#write (正確には、取り出して => write して => 成功したら削除)

```ruby
    def try_flush
      time = Engine.now

      empty = @buffer.queue_size == 0
      if empty && @next_flush_time < (now = Engine.now)
        @buffer.synchronize do
          if @next_flush_time < now
            enqueue_buffer # buffer_chunk_limit に達していなくても flush_interval が来たら enqueue する
            @next_flush_time = now + @flush_interval
            empty = @buffer.queue_size == 0
          end
        end
      end
      if empty
        return time + @try_flush_interval
      end

      begin
        retrying = !@error_history.empty?

        if retrying
          @error_history.synchronize do
            if retrying = !@error_history.empty?  # re-check in synchronize
              if @next_retry_time >= time
                # allow retrying for only one thread
                return time + @try_flush_interval
              end
              # assume next retry failes and
              # clear them if when it succeeds
              @last_retry_time = time
              @error_history << time
              @next_retry_time += calc_retry_wait
            end
          end
        end

        if @secondary && @error_history.size > @retry_limit
          has_next = flush_secondary(@secondary)
        else
          has_next = @buffer.pop(self) # queue から chunk を pop して output#write
        end

        # success
        if retrying
          @error_history.clear
          # Note: don't notify to other threads to prevent
          #       burst to recovered server
          $log.warn "retry succeeded.", :instance=>object_id
        end

        if has_next
          return Engine.now + @queued_chunk_flush_interval
        else
          return time + @try_flush_interval
        end
  ```


[BufferedOutput#enqueue_buffer](https://github.com/fluent/fluentd/blob/9fea4bd69420daf86411937addc6000dfcc6043b/lib/fluent/output.rb#L265-L269)

  ```ruby
    def enqueue_buffer
      @buffer.keys.each {|key|
        @buffer.push(key)
      }
    end
  ```

[BasicBuffer#push](https://github.com/fluent/fluentd/blob/b5dca056378257820c3ce675fa04e34d94349fa9/lib/fluent/buffer.rb#L244-L259)

flush_interval が来たので、buffer_chunk_limit に達していないが、top chunk を @queue に積み、削除している。

```ruby
    def push(key)
      synchronize do
        top = @map[key]
        if !top || top.empty?
          return false
        end

        @queue.synchronize do
          enqueue(top)
          @queue << top
          @map.delete(key)
        end

        return true
      end  # synchronize
    end
```

[BasicBuffer#pop](https://github.com/fluent/fluentd/blob/b5dca056378257820c3ce675fa04e34d94349fa9/lib/fluent/buffer.rb#L261-L293)

pop というメソッド名だが、pop するだけではなく、write (送信)もしている。
write 成功した場合のみ、取り除く。

```ruby
    def pop(out)
      chunk = nil
      @queue.synchronize do
        if @parallel_pop
          chunk = @queue.find {|c| c.try_mon_enter }
          return false unless chunk
        else
          chunk = @queue.first
          return false unless chunk
          return false unless chunk.try_mon_enter
        end
      end

      begin
        if !chunk.empty?
          write_chunk(chunk, out) # out.write(chunk) を呼び出す
        end

        empty = false
        @queue.synchronize do
          @queue.delete_if {|c|
            c.object_id == chunk.object_id
          }
          empty = @queue.empty?
        end

        chunk.purge

        return !empty
      ensure
        chunk.mon_exit
      end
    end
```

大事な補足：enqueue 処理は flush\_interval 毎に１回される。1 chunk の enqueue しかされない。
また pop (and 送信) 処理は try\_flush\_interval 毎に実行されるが、こちらも 1 chunk しか pop されない。
buffer_chunk_limit が小さい場合、十分なパフォーマンスが出ない可能性がある。

## まとめおよび補足

* BufferedOutput, BasicBuffer 周りの処理を読んだ
* buffer_chunk_limit と buffer_queue_limit
* enqueue のタイミング２つ
  * メインスレッド(ObjectBufferedOutput#emit) で、chunk にデータを追加すると buffer_chunk_limit を超える場合
  * OutputThread (ObjectBufferedOutput#try_flush) で、flush_interval 毎
* dequeue(pop) のタイミング
  * queue に次の chunk がある場合、queued_chunk_flush_interval 毎
  * queue に次の chunk がない場合、try_flush_interval 毎
  * このタイミングで 1 chunk しか output#write されないので、パフォーマンスをあげるには chunk サイズを増やすか、queued_chunk_flush_interval および try_flush_interval を短くする必要がある。
* num_threads を増やすと OutputThread の数が増えるので output#write の IO 処理が並列化されて性能向上できる可能性

性能評価結果からの補足

* パフォーマンスをあげるためには buffer_chunk_limit を増やすと良い、と行ったが実際に buffer_chunk_limit を増やすと 8m ぐらいで詰まりやすくなり、性能劣化する。[out_forward って詰まると性能劣化する？](http://togetter.com/li/595607)
* なので、buffer_chunk_limit は 1m ぐらいに保ちつつ queued_chunk_flush_interval および try_flush_interval を 0.1 など小さい値にしてじゃんじゃん吐き出すと良い

# まとめ

1. Fluentd の起動シーケンスとプラグインの読み込み
2. Input Plugin から Output Plugin にデータが渡る流れ
3. BufferedOutput プラグイン

について解説した。

Output プラグインの場合、全てのブロッキング処理がおわるまでは Input プラグインの次の入力受付の処理に戻れない、
ということについて解説した。

BufferedOutput プラグインを使ってスレッド化することによって、その問題を避けることができるが、
捌ける以上のデータを enqueue されてしまうと queue にデータが詰まってしまい、
性能劣化してしまうため、いずれにせよ実処理のスループットをあげる必要がある。
BufferedOutput プラグインを使う事でスレッド数をあげることができるので、改善できる場合は多い。

なお、このブロッキングしている時間を計測、可視化するためのツールとして、
[fluent-plugin-measure_time](https://github.com/sonots/fluent-plugin-measure_time) を作成しているのでご利用いただける。
また、このブロッキングにより、どれぐらいの間、新規に入力受付ができていなかったのかを計測、可視化するために
[fluent-plugin-latency](https://github.com/sonots/fluent-plugin-latency) というプラグインを作成しているのでご利用いただける。
