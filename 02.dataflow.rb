class CodeReadingDataflow; end

# Input Plugin から Output Plugin にデータが渡る流れ

+----------+  +----------------+   +---------+
|  Input   |  | Fluent::Engine |   | Output  |
+----+-----+  +------+---------+   +----+----+
     |               |                  |
     |   .emit       |                  |
     +--------------->    #emit         |
     |               +----------------->|
     |               |                  |
     |               <- - - - - - - - - |
     <- - - - - - - -+                  |
     |               |                  |

# 留意点
    
+----------+  +-------------+   +------------+
|  Input   |  |  Output1    |   |  Output2   |
+----+-----+  +------+------+   +-----+------+
     |  ex) in_tail  | ex) out_grep   | ex) out_growthforecast
     |               |                |
     |   #emit       |                |
     +--------------->    #emit       |
     |               +--------------->| ブロッキング!!!
     |               |                | (重い処理)
     |               <- - - - - - - - |
     <- - - - - - - -+                |
     |               |                |

ブロッキングさせたくない場合は BufferedOutput

Next: BufferedOutput プラグイン完全解説
