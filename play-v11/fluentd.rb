worker {
  source {
    type :tail
    path "/var/log/syslog"
    pos_file "/tmp/_var_log_syslog.pos"
    format "/^(?<message>.*)$/"
    time_format "%d/%b/%Y:%H:%M:%S %z"
    tag "raw.syslog"
  }
  match('raw.syslog') {
    type :stdout
    try_any ['a', 'b']
    # try_hash {a: "b"}
    try_hash '{"a":"b"}'
  }
}
worker {
  match('raw.syslog') {
    type "stdout"
    try_any "['a', 'b']"
  }
}

