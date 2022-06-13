# encoding: utf-8
#
# Copyright (c) 2006-09 Vojtech Vobr <vojta@vobr.net>
#
# This software is provided 'as-is', without any express or implied warranty.
# In no event will the authors be held liable for any damages arising from the
# use of this software.
#
# Permission is granted to anyone to use this software for any purpose,
# including commercial applications, and to alter it and redistribute it freely,
# subject to the following restrictions:
#
# 1. The origin of this software must not be misrepresented; you must not claim
#    that you wrote the original software. If you use this software in a
#    product, an acknowledgment in the product documentation would be
#    appreciated but is not required.
#
# 2. Altered source versions must be plainly marked as such, and must not be
#    misrepresented as being the original software.
#
# 3. This notice may not be removed or altered from any source distribution.
#

class LString < String
  alias :format_old :%

  def initialize(arg)
    super(arg)
    @format_args = {}
  end

  def %(arg)
    unless arg.kind_of?(Hash)
      format_old(arg)
    else
      @format_args = arg
    end

    self
  end

  def args
    @format_args
  end

  def get_translation(lang)
    translation = $l10n.translate(lang, self).dup
    @format_args.each do |k, v|
      translation.gsub!("%{#{k}}", v.to_s)
    end
    translation
  end
end

class Object
  def _(msg)
    return LString.new(msg)
  end 
end 

class Array
  def translate(lang)
    map! do |v|
      v.kind_of?(LString) ? v.get_translation(lang) : v
    end
    join("\n")
  end
end

class L10N
  attr_accessor :default_lang
  attr_reader :dict

  def initialize
    $l10n = self
    @default_lang = :en
    @dict = {}
    Dir['lang/*.lang'].each do |file|
      file =~ /lang\/(.*).lang/
      lang = $1.to_sym
      @dict[lang] = load_file(file)
    end
  end

  def load_file(file)
    trans = {}
    File.open(file, "r") do |f|
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

  def translate(lang, msg)
    lang ||= @default_lang
    lang = lang.to_s.split('-').first.to_sym unless @dict.has_key?(lang)
    lang = @default_lang unless @dict.has_key?(lang)
    @dict[lang][msg] || msg
  end
end
# vim: ts=2 sts=2 sw=2 foldmethod=marker et
