class CodeReadingBootstrap; end

# Fluentd の起動シーケンスとプラグインの読み込み

Fluent::Supervisor#run_configure
  1. require
  2. initialize
  3. configure(conf)
Fluent::Supervisor#run_engine
  4. start
  5. shutdown (シグナルを受け取ったら)

Input プラグインは start でスレッド起動
Output プラグインは start ではまだ何もしない(ことが多い)

Next: Input Plugin から Output Plugin にデータが渡る流れ
GoTo: Fluent::ForwardInput -> Fluent::StdoutOutput

