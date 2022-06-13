  def load_file(file)
    trans = {}
    File.open(file) do |f|
      key = []
      val = []
      type = :key
      f.readlines.each do |line|
        line.chomp!
        next if (line =~ /^'/)
        if line =~ /^=====\[.*?\]=====$/
          unless key.empty?
            trans[key.join("\n")] = val.join("\n")
            key = []
            val = []
          end 
          next
        end

        if line =~ /^msg: /
          line[0..4] = ""
          type = :key
        end
        if line =~ /^trans: /
          line[0..6] = ""
          type = :val
        end
        key << line if type == :key
        val << line if type == :val
      end
      trans[key.join("\n")] = val.join("\n") unless key.empty?
    end
    trans
  end

  out_file = File.new(ARGV[2], "w")
  new = load_file(ARGV[0])
  old = load_file(ARGV[1])

  new.keys.each do |k|
    new[k] = old[k] if old.has_key?(k)
  end

  used_files = [ARGV[0], ARGV[1]].join(', ')

  out_file.puts("'TransFile generated on #{Time.now.to_s} from file(s) #{used_files}\n'\n")

  new.sort.each do |k, v|
    key = k.gsub("\\n", "\n")
    val = v.gsub("\\n", "\n")
    out_file.puts("msg: #{key}\ntrans: #{val}\n=====[1]=====")
  end
  out_file.close
# vim: ts=2 sts=2 sw=2 foldmethod=marker et
