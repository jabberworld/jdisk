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
 
  # Class for handling general filepaths, files and in some cases even directories
  class DFile
    # This error gets thrown when we don't have sufficient privilegies for given operation
    class AccessDeniedError < RuntimeError
    end

    # This error gets thrown when we try to copy or move over existing one
    class FileExistsError < RuntimeError
    end

    # This error gets thrown when we are trying copy/move non existent file
    class NoSuchFileError < RuntimeError
    end

    class NoSuchUserError < RuntimeError
    end

    class NoSuchNodeError < RuntimeError
    end

    class NotSupportedError < RuntimeError
    end

    class NotEnoughSpaceError < RuntimeError
    end

    attr_reader :path
    attr_reader :fs_path
    attr_reader :unc_path
    attr_reader :name
    attr_reader :user
    attr_reader :node
    attr_reader :attrs

    FILE_READ = 1
    FILE_WRITE = 2
    FILE_DELETE = 4
    FILE_MOVE = 8

    # Initialize DFile, may throw AccessDeniedError when we are trying
    # to reach private disk of other user
    def initialize(user, node, path)

      path.sub!('\\', '/')
      path = DFile.minimize_path(path)        # normalize path

      @user = @cuser = user                   # current user
      @node = @cnode = node                   # current node

      @attrs = FILE_READ | FILE_WRITE | FILE_DELETE | FILE_MOVE   # allowed actions

      if path =~ %r{^//([^/]*)(.*)$}
        root = $1
        path = $2
        userstr, nodestr = root.split('%')
        nodestr, userstr = userstr, nil if userstr.index('@').nil?

        raise NoSuchUserError if userstr && !DUser.exist?(userstr)
        raise NoSuchNodeError if nodestr && !$nodes.has_key?(nodestr)

        @user = userstr ? DUser.new(userstr) : @cuser
        @node = nodestr ? $nodes[nodestr] : @cnode

        if @user.jid != @cuser.jid  # accessing file of another user
          @attrs = @node.public? ? FILE_READ : 0    # set proper rights
          raise AccessDeniedError if @attrs == 0
        end
      end

      @path = path
      @unc_path = DFile.concat_path("//#{@user.jid.to_s}%#{@node.node}/", @path)
      @fs_path = DFile.minimize_path(@node.get_dir(@user) + @path)
      @name = File.basename(@path)
    end

    # Updates file comment in DB
    def comment=(text) # Set/edit file comment {{{
      if text
        raise AccessDeniedError unless can_write?
        if self.comment.nil?
          $db.query("INSERT INTO filecomments (uid, nid, file, comment)
                       VALUES (#{@user.did}, #{@node.did}, '#{$db.quote(@path)}', '#{$db.quote(text)}')")
        else
          $db.query("UPDATE filecomments
                       SET comment='#{$db.quote(text)}'
                       WHERE uid=#{@user.did} AND nid=#{@node.did} AND file='#{$db.quote(@path)}'")
        end
      else
        raise AccessDeniedError unless can_delete?
        $db.query("DELETE FROM filecomments
                     WHERE uid=#{@user.did} AND nid=#{@node.did} AND file='#{$db.quote(@path)}'")
      end
    end # }}}

    # Returns file comment from DB or nil when it's not set
    def comment # Get file comment {{{
      res = $db.query("SELECT comment
                         FROM filecomments
                         WHERE uid=#{@user.did} AND nid=#{@node.did} AND file='#{$db.quote(@path)}'")
                         return nil if res.nil?

                         result = res.fetch_row
                         res.free

                         return result[0] if result
                         return nil
    end # }}}

    def move_comment_r(new_path, is_directory = false)
      raise AccessDeniedError unless can_move?

      if is_directory
        unless @path =~ %r{/$}
          @path += "/"
        end
        unless new_path =~ %r{/$}
          new_path += "/"
        end

        $db.query("UPDATE filecomments, 
                   (SELECT id comment_id,
                           CONCAT('#{$db.quote(new_path)}',
                             SUBSTRING(file, #{$db.quote(@path).length+1})) new_path
                     FROM filecomments
                     WHERE file LIKE '#{$db.quote(@path)}%'
                       AND uid=#{@user.did}
                       AND nid=#{@node.did}
                   ) AS e
                   SET file=e.new_path
                   WHERE id=e.comment_id")
      else
        $db.query("UPDATE filecomments
                     SET file = '#{$db.quote(new_path)}'
                     WHERE file = '#{$db.quote(@path)}'
                       AND uid=#{@user.did}
                       AND nid=#{@node.did}")
      end
   end

    def del_comment_r(is_directory)
      raise AccessDeniedError unless can_delete?

      if is_directory
        unless @path =~ %r{/$}
          @path += "/"
        end
        $db.query("DELETE FROM filecomments
                   WHERE uid=#{@user.did} AND nid=#{@node.did}
                     AND file like '#{$db.quote(@path)}%'")
      else
        self.comment=nil
      end
    end

    # Deletes this file/directory
    def remove # {{{
      raise AccessDeniedError unless can_delete?
      was_directory = self.directory?
      if was_directory
        Dir.rmdir(@fs_path)
      else
        filesize = self.size
        File.delete(@fs_path)
        @user.update_status(-filesize, true)
      end
      self.del_comment_r(was_directory)
    end # }}}

    # Moves this file to given path
    def move(path) # {{{
      raise AccessDeniedError unless can_move?
      raise NoSuchFileError unless exist?

      target = @cnode.grd(@cuser, path)
      target = @cnode.grd(@cuser, DFile.concat_path(path, @name)) if target.directory?

      raise FileExistsError if target.exists?
      raise AccessDeniedError unless target.can_write?

      was_directory = self.directory?

      File.rename(@fs_path, target.fs_path)

      move_comment_r(target.path, was_directory)
    end # }}}

#    # Copies this file to given path
#    def copy(path) # {{{
#      raise AccessDeniedError unless @attrs & FILE_READ
#      raise NoSuchFileError unless exist?
#
#      target = @cnode.grd(@cuser, path)
#
#      raise FileExistsError if target.exists?
#      raise AccessDeniedError unless target.can_write?
#
#      target.alloc_space(self.size)    # what to do when we copy a directory?
#
#      File.copy(@fs_path, target.fs_path)  # doesn't seem to exist on 1.8.5
#      
#      # update comment, in this way it is easier than with sql update query
#      target.comment = self.comment
#      self.comment = nil
#    end # }}}

    def alloc_space(size)
      if size
        raise NotEnoughSpaceError unless @user.alloc(size)
        @user.update_status(size, true) if size
        @user.alloc(-size)
      end
    end

    # Open file for writing 
    def open(offset = nil) # {{{
      raise NotSupportedError if self.directory?
      @file = File.new(@fs_path, offset.nil? ? 'w' : 'a')
      chown(@node.file_owner)
    end # }}}

    # Close file if it is opened
    def close # {{{
      @file.close if @file
    end # }}}

    # Write buffer into opened file
    def write(buf) # {{{
      @file.write(buf)
    end # }}}

    # Get exact file size 
    def size # {{{
      raise NotSupportedError if self.directory?
      @file.flush if @file
      File.size(@fs_path)
    end # }}}

    # Does this file even exist on FS? 
    def exist? # {{{
      File.exist?(@fs_path)
    end # }}}
    alias :exists? :exist?

    # Are we a directory? 
    def directory? # {{{
      File.directory?(@fs_path)
    end # }}}

    # Returns true when we are allowed to read from this file/directory
    def can_read? # {{{
      @attrs & FILE_READ == FILE_READ
    end # }}}

    # Returns true when we are allowed to write to this file/directory
    def can_write? # {{{
      @attrs & FILE_WRITE == FILE_WRITE
    end # }}}

    # Returns true when we are allowed to delete this file/directory
    def can_delete? # {{{
      @attrs & FILE_DELETE == FILE_DELETE
    end # }}}

    # Returns true when we are allowed to move this file/directory
    def can_move? # {{{
      @attrs & FILE_MOVE == FILE_MOVE
    end # }}}

    # Computes CRC32 hash
    def hash # {{{
      raise NotSupportedError if self.directory?
      Zlib.crc32(File.open(@fs_path, 'r').read()).to_s(16)
    end # }}}

    # Returns position of file in file's directory
    def number # {{{
      raise NotSupportedError if self.directory?
      DFile.new(@cuser, @cnode, DFile.dirname(@unc_path)).get_file_number(@name)
    end # }}}

    # Returns URL of this file when it is accessible on WWW
    def url # {{{
      if node_url = @node.get_url(@user)
        node_url[-1] = '' if node_url =~ %r{/$}
        URI.escape(node_url + @path).gsub('&', '%26')
      else
        false
      end
    end # }}}

    # Returns file creation time
    def date # {{{
      File.ctime(@fs_path)
    end # }}}
 
  ############################################################################
  # Directory only functions
  ############################################################################
 
    # Yields every directory or file in this directory
    def list # {{{
      raise AccessDeniedError unless can_read?

      Dir.foreach(@fs_path) do |file|
        next if file =~ /^\.{1,2}$/
        yield DFile.new(@cuser, @cnode, DFile.concat_path(@unc_path, file))
      end
    end # }}}

    # Returns if given relative/absolute path is valid directory
    def valid_dir?(path) # {{{
      DFile.new(@cuser, @cnode, DFile.concat_path(@unc_path, path)).directory?
    end # }}}

    # Returns number of given file in this directory
    def get_file_number(name) # {{{
      cntr = 1
      Dir.foreach(@fs_path) do |file|
        next if file =~ /^\.{1,2}$/
        unless File.directory?(@fs_path+file)
          return cntr if file == name
          cntr += 1
        end
      end
      false
    end # }}}

    def get_files(params)
      files = []

      # slash at the end would cause problems (endless recursion "/" or invalid paths "n/" would expand to "n/n")
      params.sub!(/\/$/, "")  

      if DFile.dirname(params) != nil 
        DFile.new(@cuser, @cnode, DFile.concat_path(@unc_path, DFile.dirname(params))).get_files(File.basename(params))  # get to given dir and call us recursively
      else
        params = File.basename(params)
        if params =~ /^#([0123456789,-]+)$/  # numbered files (like #2 or 3-5 or #1,3,5-8)
          nums = []
          pars = $1.split(/,/)
          pars.each do |par|
            if par =~ /(\d+)-(\d+)/
              nums << ($1.strip.to_i..$2.strip.to_i).to_a
            else
              nums << par.strip.to_i
            end
          end
          nums.flatten!
          cntr = 1
          list do |file|
            unless file.directory?
              files << file if nums.include?(cntr)
              cntr += 1
            end
          end
        elsif params == '*'           # all files
          list do |file|
            unless file.directory?
              files << file
            end
          end
        end

        if files.empty?
          file = DFile.new(@user, @node, DFile.concat_path(@unc_path, params))
          files << file if file.exists?
        end

        raise NoSuchFileError if files.empty?               # file name
      
        files
      end
    end

    # recursively create a new dir
    def mkdir(path) # {{{
      new_dir = DFile.new(@cuser, @cnode, DFile.concat_path(@unc_path, path))
      raise AccessDeniedError unless new_dir.can_write?
      mkdir_r(new_dir.fs_path, new_dir.node.file_owner) 
    end # }}}

    # similar to mkdir_p, but can change owner 
    def mkdir_r(dir, owner) # {{{
      dir.sub!(/\/\z/, '')
      begin
        Dir.mkdir(dir)
        File.chown(owner, nil, dir) if owner >= 0
        return true
      rescue SystemCallError
        return true if File.directory?(dir)
      end

      stack = []
      until dir == stack.last
        stack.push dir
        dir = File.dirname(dir)
      end

      stack.reverse_each do |dir|
        begin
          Dir.mkdir(dir)
          File.chown(owner, nil, dir) if owner >= 0
        rescue SystemCallError
          return false unless File.directory?(dir)
        end
      end

      return true
    end # }}}

    def DFile::minimize_path(path) # {{{
      unc = path =~ %r{^//[^/.]} # valid UNC path has only two slashes at the beginning followed by a name
      root = path =~ %r{^/[^/.]} # valid rooted path has only one slash at the beginning followed by a name
      arr = path.split("/")
      out = []

      while !(arr.empty?)
        tmp = arr.shift
        if tmp == ".."
          out.pop if !unc || out.length > 1
        elsif !(["", "."].include?(tmp))
          out << tmp
        end
      end

      (unc ? "//" : (root ? "/" : "")) + out.join("/")
    end # }}}

    def DFile::concat_path(base_dir, path) # {{{

      base_dir.sub!('\\', '/')
      path.sub!('\\', '/')

      concat = nil
      if path =~ %r{^//}
        concat = path
      elsif path =~ %r{^/}
        if base_dir =~ %r{//([^/]*)}
          concat = "//" + $1 + path
        else
          concat = path
        end
      else
        base_dir.sub!(/\/$/, "")
        path.sub!(/^\//, "")
        concat = base_dir + '/' + path
      end

      #DFile::minimize_path(concat)
      concat
    end # }}}

    def DFile::dirname(path)
      path =~ %r{^(.*/)[^/]*$}
      $1
    end

    protected

    def chown(owner)
      File.chown(owner, nil, @fs_path) if owner > 0
    end
  end
end


#DFile.new('//public%jjk@jabbim.cz/test/xyz.txt', 'album', 'test@xy')
#DFile.new('//public/test/xyz.txt', 'private', 'jjk@xx')
#DFile.new('//jjk@jabbim.cz/test/xyz.txt', 'public', 'jjky')
#
#puts DFile.concat_path("//test/ecs/test", "abc")
#puts DFile.concat_path("//test/ecs/test/", "abc")
#puts DFile.concat_path("//test/ecs/test/", "/abc")
#puts DFile.concat_path("//test/ecs/test/", "//abc/test")
#puts DFile.concat_path("//test/ecs/test/", "../../../../../abc/test")
#puts DFile.concat_path("//test/ecs/test/", "../abc/test")
#puts DFile.concat_path("//test/ecs/test", "../abc/test")
#puts DFile.concat_path("//test/ecs/test", "/abc/../test")
#puts DFile.concat_path("/test/ecs/test/", "../../../../../abc/test")
#puts DFile.concat_path("/test/ecs/test/", "../../../../../")
#puts DFile.concat_path("/test/ecs/test/", "/abc")
#puts DFile.concat_path("/test/ecs/test/", "//abc/test")
#puts DFile.concat_path("", "/test/../../../../../")
#puts DFile.concat_path("/", "test/../../../../../")
#puts DFile.concat_path("/", "/test/../../../../../")
#puts DFile.concat_path("/test/abc", "// ////")+"'"
#puts DFile.concat_path("//test/abc", "// ////")+"'"
#puts DFile.concat_path("/test/abc", "//./")
#puts DFile.concat_path("//test/abc", "//./")
#puts DFile.concat_path("/test/abc", "///")
#puts DFile.concat_path("//test/abc", "///")
#puts DFile.concat_path("/test/abc", "//")
#puts DFile.concat_path("//test/abc", "//")

# vim: ts=2 sts=2 sw=2 foldmethod=marker et
