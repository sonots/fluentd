require 'fluentd/plugin_spec_helper'
require 'fluentd/plugin/filter_copy'

include Fluentd::PluginSpecHelper

describe Fluentd::Plugin::CopyFilter do
  config = %[
    type copy
  ]
  driver = generate_driver(Fluentd::Plugin::CopyFilter, config)

  it 'copy events' do
    t = Time.now.to_i
    driver.run('xxx', t) do |d|
      d.pitch({"f1"=>"data1", "f2"=>"data2"})
      d.pitch({"f1"=>"data1", "f2"=>"data2"})
      d.pitch({"f1"=>"data1", "f2"=>"data2"})
      d.pitch({"f1"=>"data1", "f2"=>"data2"})
    end

    expect(driver.events.keys.size).to eql(1)
    expect(driver.events.keys.first).to eql('xxx')
    expect(driver.events['xxx'].size).to eql(4)
    driver.events['xxx'].each do |e|
      expect(e.r).to eql({"f1"=>"data1", "f2"=>"data2"})
    end
  end
end
