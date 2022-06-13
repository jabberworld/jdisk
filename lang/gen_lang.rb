trans = {}
files = {}

Dir.glob('../*.rb').each do |file|
    f = File.new(file,"r")
    f.each_line do |line|
        if line =~ /_\("(.*?)"\)/
            trans[$1] = 0 unless trans.has_key?($1)
            trans[$1] += 1
            files[file] = 0 unless files.has_key?(file)
            files[file] += 1
        end
    end
end

out_file = File.new("new_en.lang", "w")

used_files = files.keys.join(", ")

out_file.puts("'TransFile generated on #{Time.now.to_s} from file(s) #{used_files}\n'\n")

trans.sort.each do |k, v|
    key = k.gsub("\\n", "\n")
    out_file.puts("msg: #{key}\ntrans: #{key}\n=====[#{v}]=====")
end

out_file.close
