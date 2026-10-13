# Hand-written model exercising the Oxidized model API, written the way
# Oxidized models often are: it patches core classes and defines globals.

class String
  def rootware_patched? = true
end

$rootware_global = true
ROOTWARE_CONSTANT = 1

class RootWare < Oxidized::Model
  using Refinements

  prompt /^rt[#>] ?$/
  comment '! '

  expect /--More--/ do |data, re|
    send ' '
    data.sub re, ''
  end

  cmd :all do |cfg|
    cfg.cut_both
  end

  cmd :secret do |cfg|
    cfg.gsub(/^(snmp community) \S+/, '\\1 <hidden>')
  end

  cmd 'show version' do |cfg|
    comment cfg
  end

  cmd 'show config'

  pre do
    comment "model #{vars(:site)} #{vars(:verbose).inspect}\n"
  end

  post do
    cmd('show extra') { |cfg| comment cfg } if vars(:verbose) == true
  end

  cfg :telnet do
    username /^login:/
    password /^Password:/
  end

  cfg :telnet, :ssh do
    post_login do
      if vars(:enable)
        cmd 'enable', /^Password:/
        cmd vars(:enable)
      end
    end
    post_login 'terminal length 0'
    pre_logout 'exit'
  end
end
