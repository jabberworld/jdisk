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

module JDisk
  class Disk
    def cmd_intro(params, disk_node, user) # introduction {{{
      nodes = $nodes.keys.map{|k| $l10n.translate(user.lang, k)}.join(", ")
      [$help["intro"] % {:cmd => $help.keys.join(", "), :public_url => $nodes["public"].get_url(user), :nodes => nodes}]
    end # }}}
    $help = {"intro" => _("To upload a file to JDisk send that file to one of the disk contacts.\nBelow is list of commands which can be used for maintaining uploaded files, for more information about a command please write 'help <command>'.\nExample: help help (i.e. without the quotes and < > characters)\n\nSome commands accept a path, which can be in several forms:\n - //user@server%node/dir/file - full path to file, this syntax can be used to easily access public files of other users or files on different nodes. When user@server% or %node is omitted from the path the current user or node will be used. Node can be one of %{nodes}.\n - /dir/file, ../dir/file - absolute and relative paths on given node, relative paths are based on current directory.\n - dir/#1 - each file in a directory has a number by which it can be referenced. The number can be obtained by the 'ls' command. A file's number can however change in time with changes made to a directory (deleting files, uploading new files etc.). It is also possible to 'select' more than one file with this method (when supported by the command).\n Example: #1,2,4-6 would select files 1, 2, 4, 5, 6\n\nFiles uploaded to public node can be accessed on the web by url %{public_url}\n\nAvailable commands: %{cmd}")}

    def cmd_help(params, disk_node, user) # help command {{{
      if params.empty? || !$help.has_key?(params.first) || params.first == "intro"
        cmd_intro(params, disk_node, user)
      elsif params.first == "lang"  # special case, cannot by created during initialization
        [$help[params.first] % {:languages => $l10n.dict.keys.join(", ")}]
      else
        [$help[params.first]]
      end
    end # }}}
    $help["help"] = _("help <command> - prints possible commands or when command name is given as a parameter prints detailed help for that command")

    def cmd_admin(params, disk_node, user) # Admin command {{{ 
      return [] unless $conf['admins'].include?(user.jid.to_s)

      out = []

      case params.shift
        when /^help$/i
          out << _("help, exit, listincoming, remincoming, load, debug, recount")
        when /^exit$/i
          @mainThread.wakeup
        when /^listincoming$/i
          $incoming.each do |k, v|
            out << "#{k}: #{v[1]}/#{v[4]}B, #{v[2]}x #{v[3]}\n"
          end
        when /^remincoming$/i
          $incoming.delete(params.join(" "))
          out << "#{params.join(" ")} has been removed!"
        when /^load$/i
          begin
            load params.first
          rescue Exception => e
            out << "Load of #{params.first} failed"
          end
          out << "Load End"
        when /^debug$/i
          if params.first =~ /enable/i
            Jabber::debug = true
          elsif params.first =~ /disable/i
            Jabber::debug = false
          end
        when /^recount$/i
          cntr = 0
          $nodes.values.first.subscribed do |user|
            duser = DUser.new(user)
            duser.get_used_stats
            cntr += 1
          end
          out << "Processed #{cntr} users"
      end

      out
    end # }}}

    def cmd_ls(params, disk_node, user)  # ls command {{{
      out = []

      if params.first =~ /^-/
        sort = params.shift
      else
        sort = nil
      end

      directory = params.shift || ""

      cntr = 1

      if (dir = disk_node.grd(user, directory)).exist?

        dirs = []
        files = []

        dir.list do |file|
          if !file.directory?
            files << [cntr, file]
            cntr += 1
          else
            dirs << file.name 
          end
        end

        dirs.sort.each do |name|
          out << _("<dir> %{name}/") % {:name => name}
        end

        case sort
          when /^-d$/i
            files.sort! {|f1, f2| f1[1].date <=> f2[1].date}
          when /^-n$/i
            files.sort! {|f1, f2| f1[1].name <=> f2[1].name}
        end

        files.each do |name|
          out << "#{name[0]} - #{name[1].name} [#{name[1].size.to_file_size}] - #{name[1].comment}"
        end
      else
        out << _("Invalid directory")
      end

      out << _("There is no file in the directory") if out.empty?

      out
    rescue DFile::NoSuchUserError
      [_("Given user doesn't exist")]
    rescue DFile::NoSuchNodeError
      [_("Given node doesn't exist")]
    rescue DFile::AccessDeniedError
      [_("Given directory is not accessible to you")]
    end # }}}
    $help["ls"] = _("ls [-d|-n] <path> - lists contents of the current directory. When a path is given, the contents of that path are listed when possible.\n -d sorts files by creation date\n -n sorts files by name")

    def cmd_cd(params, disk_node, user)  # change dir command {{{

      return cmd_help(["cd"], disk_node, user) if params.empty?

      path = params.join(" ")

      if disk_node.cwd(user, path)
        [_("ok")]
      else
        [_("Invalid directory")]
      end
    rescue DFile::NoSuchUserError
      [_("Given user doesn't exist")]
    rescue DFile::NoSuchNodeError
      [_("Given node doesn't exist")]
    end # }}}
    $help["cd"] = _("cd <path> - change current directory to the given path. The current directory cannot be set to that of another node or user")

    def cmd_pwd(params, disk_node, user) # print working dir command {{{
      [disk_node.get_working_dir(user)]
    end # }}}
    $help["pwd"] = _("pwd - prints current working directory")

    def cmd_mkdir(params, disk_node, user) # make dir command {{{

      return cmd_help(["mkdir"], disk_node, user) if params.empty?

      path = params.shift

      if disk_node.gwd(user).mkdir(path)
        [_("Directory %{path} has been successfully created") % {:path => path}]
      else
        [_("Failed creating given directory")]
      end
    rescue DFile::NoSuchUserError
      [_("Given user doesn't exist")]
    rescue DFile::NoSuchNodeError
      [_("Given node doesn't exist")]
    end # }}}
    $help["mkdir"] = _("mkdir <path> - makes new directory on given path")

    def cmd_get(params, disk_node, user)  # get command {{{

      return cmd_help(["get"], disk_node, user) if params.empty?

      path = params.shift

      disk_node.gwd(user).get_files(path).each do |dfile|
        disk_node.send_file(Jabber::JID.new(user.full_jid), dfile)
      end
      []
    rescue DFile::NoSuchFileError
      [_("File '%{file}' doesn't exist") % {:file => path}]
    rescue DFile::NoSuchUserError
      [_("Given user doesn't exist")]
    rescue DFile::NoSuchNodeError
      [_("Given node doesn't exist")]
    rescue DFile::AccessDeniedError
      [_("Insufficient privileges")]
    end # }}}
    $help["get"] = _("get <path> - sends you given file")

    def cmd_send(params, disk_node, user)  # send command {{{

      return cmd_help(["send"], disk_node, user) if params.size < 2

      out = []

      jid = params.shift
      path = params.shift

      if Jabber::JID.new(jid).domain != $c.jid.domain
        disk_node.gwd(user).get_files(path).each do |dfile|
        
          if disk_node.send_file(Jabber::JID.new(jid), dfile, _("File is being sent by the user '%{user}'") % {:user => user.jid.to_s}, user)
            disk_node.send_msg(user, _("File '%{file}' has been sent") % {:file => dfile.name})   # Need to response immediately, do not return it in out
          else
            out << _("File '%{file}' couldn't be sent") % {:file => dfile.name}
          end
        end
      else
        out << _("Jabber Disk cannot send a file to itself")
      end

      out
    rescue DFile::NoSuchFileError
      [_("File '%{file}' doesn't exist") % {:file => path}]
    rescue DFile::NoSuchUserError
      [_("Given user doesn't exist")]
    rescue DFile::NoSuchNodeError
      [_("Given node doesn't exist")]
    rescue DFile::AccessDeniedError
      [_("Insufficient privileges")]
    end # }}}
    $help["send"] = _("send <jid/resource> <path> - sends the given file to the given user. The JID must be a full JID (with a resource), otherwise the file cannot be sent")

    def cmd_du(params, disk_node, user)  # disk used command {{{
      old_brief = user.get_used_stats(false, true)
      stats = user.get_used_stats
      new_brief = user.get_used_stats(false, true)

      if old_brief.args != new_brief.args
        user.send_presence(new_brief)
      end

      [stats]
    end # }}}
    $help["du"] = _("du - prints statistics about used disk space")

    def cmd_mv(params, disk_node, user)  # move command {{{

      return cmd_help(["mv"], disk_node, user) if params.size < 2

      out = []
          
      source = params.shift
      target = params.shift

      disk_node.gwd(user).get_files(source).each do |file|
        begin
          file.move(target) 
          out << _("File '%{file}' has been moved to '%{target}'") % {:file => file.name, :target => target}
        rescue SystemCallError
          out << _("File '%{file}' cannot be moved, the target directory probably doesn't exist") % {:file => file.name}
        rescue DFile::AccessDeniedError
          out << _("Insufficient privileges to move file '%{file}' to given target")
        rescue DFile::FileExistsError
          out << _("Target file '%{file}' already exists") % {:file => target}
        end
      end
    
      out
    rescue DFile::NoSuchFileError
      [_("File '%{file}' doesn't exist") % {:file => source}]
    rescue DFile::NoSuchUserError
      [_("Given user doesn't exist")]
    rescue DFile::NoSuchNodeError
      [_("Given node doesn't exist")]
    rescue DFile::AccessDeniedError
      [_("Insufficient privileges")]
    end # }}}
    $help["mv"] = _("mv <source> <target> - moves source file to target file")

#    File.copy doesn't seem to exist on ruby 1.8.5?
#    DFile.copy would need more work anyway ...
#    def cmd_cp(params, disk_node, user)  # copy command {{{
#
#      return cmd_help(["cp"], disk_node, user) if params.size < 2
#
#      out = []
#          
#      source = params.shift
#      target = params.shift
#
#      disk_node.gwd(user).get_files(source).each do |file|
#        begin
#          file.copy(target) 
#          out << _("File '%{file}' has been copied") % {:file => file.name}
#        rescue SystemCallError
#          out << _("File '%{file}' cannot be copied, the target directory probably doesn't exist") % {:file => file.name}
#        rescue DFile::NotEnoughSpaceError
#          out << _("Cannot copy file '%{file}', not enough space on target") % {:file => file.name}
#        rescue DFile::AccessDeniedError
#          out << _("Insufficient privileges to copy file '%{file}' to given target") % {:file => file.name} 
#        rescue DFile::FileExistsError
#          out << _("Target file '%{file}' already exists") % {:file => target}
#        end
#      end
#    
#      out
#    rescue DFile::NoSuchFileError
#      [_("File '%{file}' doesn't exist") % {:file => path}]
#    rescue DFile::NoSuchUserError
#      [_("Given user doesn't exist")]
#    rescue DFile::NoSuchNodeError
#      [_("Given node doesn't exist")]
#    rescue DFile::AccessDeniedError
#      [_("Insufficient privileges")]
#    end # }}}
    
    def cmd_rm(params, disk_node, user)  # rm command {{{

      return cmd_help(["rm"], disk_node, user) if params.empty?

      out = []

      path = params.shift
      old_brief = user.get_used_stats(false, true)

      disk_node.gwd(user).get_files(path).each do |file|
        begin
          dir = file.directory?
          file.remove
          if dir
            out << _("Directory '%{file}' has been removed") % {:file => file.name}
          else
            out << _("File '%{file}' has been removed") % {:file => file.name}
          end
        rescue SystemCallError
          out << _("Cannot delete '%{file}'") % {:file => file.name}
        rescue DFile::AccessDeniedError
          out << _("Insufficient privileges")
        end
      end

      new_brief = user.get_used_stats(false, true)

      if old_brief.args != new_brief.args
        user.send_presence(new_brief)
      end

      out
    rescue DFile::NoSuchFileError
      [_("File '%{file}' doesn't exist") % {:file => path}]
    rescue DFile::AccessDeniedError
      [_("Insufficient privileges")]
    rescue DFile::NoSuchUserError
      [_("Given user doesn't exist")]
    rescue DFile::NoSuchNodeError
      [_("Given node doesn't exist")]
    end # }}}
    $help["rm"] = _("rm <path> - deletes given path")

    def cmd_link(params, disk_node, user)  # link command {{{

      return cmd_help(["link"], disk_node, user) if params.empty?

      out = []

      path = params.shift

      disk_node.gwd(user).get_files(path).each do |file|
        if url = file.url
          out << url
        else
          out << _("File '%{file}' is not accessible via the web interface") % {:file => file.name}
        end
      end

      out
    rescue DFile::NoSuchFileError
      [_("File '%{file}' doesn't exist") % {:file => path}]
    rescue DFile::AccessDeniedError
      [_("Insufficient privileges")]
    rescue DFile::NoSuchUserError
      [_("Given user doesn't exist")]
    rescue DFile::NoSuchNodeError
      [_("Given node doesn't exist")]
    end # }}}
    $help["link"] = _("link <path> - prints URL of given file when it is accessible on the web")
    
    def cmd_hash(params, disk_node, user)  # hash command, computes CRC32 {{{

      return cmd_help(["hash"], disk_node, user) if params.empty?

      out = []

      path = params.shift

      disk_node.gwd(user).get_files(path).each do |dfile|
        out << ("#{dfile.number} - CRC32: #{dfile.hash} #{dfile.name}"+
                "[#{dfile.size.to_file_size}] - #{dfile.comment}")
      end

      out
    rescue DFile::NotSupportedError
      [_("Cannot calculate hash of directory")]
    rescue DFile::NoSuchFileError
      [_("File '%{file}' doesn't exist") % {:file => path}]
    rescue DFile::AccessDeniedError
      [_("Insufficient privileges")]
    rescue DFile::NoSuchUserError
      [_("Given user doesn't exist")]
    rescue DFile::NoSuchNodeError
      [_("Given node doesn't exist")]
    end # }}}
    $help["hash"] = _("hash <path> - prints CRC32 of given file")
    
    def cmd_lang(params, disk_node, user)  # sets user language {{{

      return cmd_help(["lang"], disk_node, user) if params.empty?

      out = []

      if params.length == 1
        user.lang = params.first == "none" ? nil : params.shift
        out << _("Language has been set")
      else
        out << $strs[:langhelp]
      end

      out
    end # }}}
    $help["lang"] = _("lang <lang_code> - sets disk language. This setting overrides the language sent by your client.\nEnter 'none' as the lang_code to reset the language to the default (the one sent by your client).\nSupported languages: %{languages}")
  end
end

# vim: ts=2 sw=2 sts=2 foldmethod=marker et
