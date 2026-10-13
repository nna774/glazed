class Unredactable < Oxidized::Model
  cmd :secret do |cfg|
    cfg.each_line.grep_v(/secret/).join
  end

  cmd 'show config'

  cfg :ssh do
  end
end
