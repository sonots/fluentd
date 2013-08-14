require 'fluentd/plugin_spec_helper'
require 'fluentd/plugin/filter_retag'

include Fluentd::PluginSpecHelper

describe Fluentd::Plugin::RetagFilter do
  config = %[
    type retag
    tag  yyy
  ]
  driver = generate_driver(Fluentd::Plugin::RetagFilter, config)

  it 'copy events' do
    t = Time.now.to_i
    driver.run do |d|
      d.pitch({"f1"=>"data1", "f2"=>"data2"})
      d.pitch({"f1"=>"data1", "f2"=>"data2"})
      d.pitch({"f1"=>"data1", "f2"=>"data2"})
      d.pitch({"f1"=>"data1", "f2"=>"data2"})
    end
    driver.run('xxx', t) do |d|
      d.pitch({"f1"=>"data1", "f2"=>"data2"})
      d.pitch({"f1"=>"data1", "f2"=>"data2"})
      d.pitch({"f1"=>"data1", "f2"=>"data2"})
      d.pitch({"f1"=>"data1", "f2"=>"data2"})
    end

    expect(driver.events.keys.size).to eql(1)
    expect(driver.events.keys.first).to eql('yyy')
    expect(driver.events['yyy'].size).to eql(4)
    driver.events['yyy'].each do |e|
      expect(e.r).to eql({"f1"=>"data1", "f2"=>"data2"})
    end
  end
end
