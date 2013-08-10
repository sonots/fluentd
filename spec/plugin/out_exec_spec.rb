require 'fluentd/plugin_spec_helper'
require 'fluentd/plugin/out_exec'
require 'fileutils'
require 'time'

include Fluentd::PluginSpecHelper

describe Fluentd::Plugin::ExecOutput do
  def setup
    FileUtils.rm_rf(TMP_DIR)
    FileUtils.mkdir_p(TMP_DIR)
  end

  TMP_DIR = File.dirname(__FILE__) + "/../tmp"

  CONFIG = %[
    buffer_path "#{TMP_DIR}/buffer"
    command "cat >#{TMP_DIR}/out"
    keys "time,tag,k1"
    tag_key tag
    time_key time
    time_format "%Y-%m-%d %H:%M:%S"
  ]

  def create_driver(conf = CONFIG)
    generate_driver(Fluentd::Plugin::ExecOutput, conf)
  end

  it 'test configure' do
    d = create_driver

    expect(d.instance.keys).to eql(["time","tag","k1"])
    expect(d.instance.tag_key).to eql("tag")
    expect(d.instance.time_key).to eql("time")
    expect(d.instance.time_format).to eql("%Y-%m-%d %H:%M:%S")
  end

  def test_format
    d = create_driver

    time = Time.parse("2011-01-02 13:14:15").to_i
    d.with('test', time) do |d|
      d.pitch({"k1"=>"v1","kx"=>"vx"})
      d.pitch({"k1"=>"v2","kx"=>"vx"})
    end

=begin
    d.expect_format %[2011-01-02 13:14:15\ttest\tv1\n]
    d.expect_format %[2011-01-02 13:14:15\ttest\tv2\n]

    d.run
=end
  end

  it 'test write' do
    d = create_driver

    time = Time.parse("2011-01-02 13:14:15").to_i
    d.with('test', time) do |d|
      d.pitch({"k1"=>"v1","kx"=>"vx"})
      d.pitch({"k1"=>"v2","kx"=>"vx"})
    end

    d.instance.send(:try_flush)

    expect_path = "#{TMP_DIR}/out"
    expect(File.exist?(expect_path)).to be_true

    data = File.read(expect_path)
    expect_data =
      %[2011-01-02 13:14:15\ttest\tv1\n] +
      %[2011-01-02 13:14:15\ttest\tv2\n]
    expect(data).to eql(expect_data)
  end
end
