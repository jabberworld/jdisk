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

require 'find'

module JDisk
  class DNode
    attr_reader :did      # Database ID
    attr_reader :node
    attr_reader :jid
    attr_reader :name
    attr_reader :url
    attr_reader :file_owner
    attr_reader :file_dir

    def initialize(node)  # Initialize a node, send presence to subscribed users {{{
      @node = node.downcase
      @jid = Jabber::JID.new(@node, $c.jid.to_s, $conf['resource'])
      @file_owner = $conf['nodes'][node]['owner'].to_i
      @file_dir = $conf['nodes'][node]['dir']
      @name = $conf['nodes'][node]['name']
      @url = $conf['nodes'][node]['url']
      
      # Get node id
      res = $db.query("SELECT id FROM nodes WHERE name='#{$db.quote(@node)}'")
      unless res.nil?
        @did = (result = res.fetch_row) ? result.first : nil
        res.free
      end

      if @did.nil?
        $db.query("INSERT INTO nodes (name) VALUES ('#{$db.quote(@node)}')")
        @did = $db.insert_id
      end
    end # }}}

    def public?
      !@url.nil?
    end

    def get_working_dir(user)
    
      res = $db.query("SELECT cwd  FROM subscriptions WHERE uid = #{user.did} and nid = #{@did}")
      working_dir = nil

      unless res.nil?
        working_dir = (result = res.fetch_row) ? result.first : nil
      end

      working_dir = '/' unless working_dir
      
      working_dir
    end

    def gad(user, path) # Get Absolute Dir
      DFile.new(user, self, path)
    end

    def gwd(user)
      DFile.new(user, self, get_working_dir(user))
    end

    def grd(user, path)
      DFile.new(user, self, DFile.concat_path(get_working_dir(user), path))
    end

    def cwd(user, dir)
      if (wd = grd(user, dir)).directory?
        if (wd.user.jid == user.jid) && (wd.node.node == self.node)
          $db.query("INSERT INTO subscriptions (uid, nid, cwd) VALUES ('#{user.did}', '#{@did}', '#{$db.quote(wd.path)}') ON DUPLICATE KEY UPDATE cwd = '#{$db.quote(wd.path)}'")
          return true
        end
      end
      false
    end

    def subscribed(user=nil) # {{{
      unless user
        res = $db.query("SELECT u.jid FROM users u, subscriptions n WHERE n.nid=#{@did} AND u.id = n.uid")
        return if res.nil?

        res.each { |row| yield row.first }
        res.free
      else
        res = $db.query("SELECT true FROM subscriptions n WHERE n.uid = #{user.did} AND n.nid = #{@did}")
        return false if res.nil?

        if row = res.fetch_row
          result = false
          result = row.first
          res.free
          return result
        else
          return false
        end
      end
    end # }}}

    def set_subscribed(user, value) # {{{
      query = ""
      if value
        query = "INSERT IGNORE INTO subscriptions (uid, nid) VALUES (#{user.did}, #{@did})"
      else
        query = "DELETE FROM subscriptions WHERE uid=#{user.did} AND nid=#{@did}"
      end
      $db.query(query)
    end # }}}

    def get_url(user) # Returns url of given user {{{
      ! url.nil? ? url.gsub('{jid}', user.jid.to_s) : false
    end # }}}

    def get_dir(user)                  # Podle node navrati spravny adresar pro dane jid {{{

      if user.kind_of?(JDisk::DUser)
        jid = user.jid.to_s 
      elsif user.kind_of?(Jabber::JID)
        jid = user.strip.to_s
      else
        jid = user
      end

      user_dir = @file_dir.gsub('{jid}', jid)
      
      unless File::exist?(user_dir)
        FileUtils::mkdir_p(user_dir)
        File.chown(@file_owner, nil, user_dir) if @file_owner >= 0
      end
      user_dir
    end # }}}
 
    def get_used_space(user) # Counts used space on this node {{{
      size = 0
      Find.find(get_dir(user)) do |file| size += File.stat(file).size end
      size
    end # }}}

    def send_msg(user, message, lang=nil)         # Odesle zpravu danemu kontaktu {{{
      jid = nil

      if user.kind_of?(JDisk::DUser)
        jid = user.full_jid
        lang = user.lang unless user.lang.nil?
      else
        jid = user
      end

      lang = lang.to_sym unless lang == "" or lang == nil
      message = message.translate(lang) if message.kind_of?(Array)
      message = message.get_translation(lang) if message.kind_of?(LString)
      msg = Jabber::Message.new(jid, message).set_type(:chat).set_from(@jid)
      msg.lang = lang if lang
      $c.send(msg)
    end # }}}
    
    def send_presence(user, status='', type=nil, show=nil, lang=nil)
      jid = nil

      if user.kind_of?(JDisk::DUser)
        jid = user.jid
        lang = user.lang
      else
        jid = user
      end

      lang = lang.to_sym unless lang == "" or lang == nil
      status = status.translate(lang) if status.kind_of?(Array)
      status = status.get_translation(lang) if status.kind_of?(LString)
      from_jid = [:subscribe, :subscribed].include?(type) ? @jid.strip : @jid
      presence = Jabber::Presence.new(show=nil, status=status).set_to(jid).set_type(type).set_from(from_jid)
      presence.add($caps)
      $c.send(presence)
    end

    def incoming_file(iq, file)       # Incoming file callback {{{
      user = DUser.new(iq.from, iq.lang)
      dFile = grd(user, file.fname) # get relative dir, but works for files too :)
      incoming_name = user.full_jid.to_s + ' - ' + @node + ' - ' + dFile.path

      if ! user.alloc(file.size)    # Try allocate some space for file
        $log.info("<<") {"DENY AVAIL #{user.jid.to_s} - #{@node} - #{file.fname}"}
        send_msg(user, _("There is not enough space to upload this file"))
        $ft.decline(iq)
      elsif $incoming.has_key?(incoming_name)
        $log.info("<<") {"DENY INCOMING #{user.jid.to_s} - #{@node} - #{file.fname}"}
        send_msg(user, _("This file is already being uploaded"))
        $ft.decline(iq)
      else
        Thread.new do
          begin
            begin
              $incoming[incoming_name] = [Thread.current, 0, 0, 'i', file.size]
              zapsano_bytu = 0

              $log.info("<<") {"INIT #{user.jid.to_s} - #{@node} - #{dFile.path} - #{file.description}"}

              offset = nil
              if dFile.exist?        # remove file if exist
                if dFile.size < file.size and file.range != nil
                  offset = dFile.size
                  $log.info("<<") {"RANGE #{user.jid.to_s} - #{@node} - #{dFile.path} - #{offset} - #{file.size}"}
                else
                  # TODO: settings to allow user choose if overwrite file or append or ...
                  dFile.remove
                end
              end
     
              $incoming[incoming_name][3] = '1'
              stream = $ft.accept(iq, offset)
              stream.connect_timeout = 15 if stream.kind_of?(Jabber::Bytestreams::SOCKS5Bytestreams)
              $incoming[incoming_name][3] = '2'
             
              if stream.accept
              $incoming[incoming_name][3] = '3'
                $log.info("<<") {"ACCEPTED #{user.jid.to_s} - #{@node} - #{dFile.path}"}
            
                dFile.open(offset)
                
                buf = nil
                while true
                  $incoming[incoming_name][3] = 'r'
                  if stream.kind_of?(Jabber::Bytestreams::IBBTarget)
                    Timeout::timeout(120) { buf = stream.read } # IBB stream don't have length parameter should be also bit slower -> higher timeout
                  else
                    Timeout::timeout(90) { buf = stream.read(32768) } # 90 seconds should be enough
                  end
                  break unless buf

                  if $incoming.has_key?(incoming_name) 
                    $incoming[incoming_name][3] = 'w' 
                    dFile.write(buf) 
                    zapsano_bytu += buf.size 
                    $in_bytes += buf.size 
                    $incoming[incoming_name][1] += buf.size 
                    $incoming[incoming_name][2] += 1 
                  else 
                    $log.error("!!!") {"#{iq.from.strip.to_s} and #{dFile.path} doesn't exist in $incoming"} 
                  end 
                end
                
                $in_files += 1
                $log.info("<<") {"DONE #{user.jid.to_s} - #{@node} - #{dFile.path} - #{file.description}"}
                dFile.comment = (file.description || "")

                if dFile.size < file.size
                  send_msg(user, "Uploaded file size is smaller than your client told, it seems like data will be corrupted.")
                  $log.info("<<") {"Corrupted upload #{dFile.size}/#{file.size}"}
                else   # upload finished successfully
                  $plugins.each do |plug|
                    if plug.respond_to?("hook_upload_finished")
                      plug.hook_upload_finished(user.jid, @node, dFile.path)
                    end
                  end
                end

                
                send_msg(user, "##{dFile.number} - #{dFile.url}") if public?
                
                stream.close
              else
                $log.info("<<") {"ERR CONN #{user.jid.to_s} - #{@node} - #{dFile.path}"}
              end
            rescue Timeout::Error
              send_msg(user, _("Transfer of file '%{file}' has timed out, please try again") % {:file => dFile.name})
              $log.info("<<") {"ERR TIMEOUT #{user.jid.to_s} - #{@node} - #{dFile.path}"}
            rescue Exception => e
              $log.error {"#{e}: #{e.backtrace.join("\n")}"}
            ensure
              $incoming.delete(incoming_name)
              user.alloc(-file.size)   # free allocated space on disk
              
              dFile.close

              ussage = user.get_used_stats(exact=true, brief=true)
              user.send_presence(ussage)
            end
          rescue Exception => e
            $log.error {"#{e}: #{e.backtrace.join("\n")}"}
          end
        end
      end
    end # }}}

    def send_file(to, file, comment = "", confirm_acceptance_to = nil) # Odesle soubor danemu kontaktu {{{
      begin
        $log.info(">>") {"SEND #{file.path} - #{to.to_s} - #{@jid.to_s}"}
      
        source = Jabber::FileTransfer::FileSource::new(file.fs_path)
        comment += "\n" + (file.comment || "")
        stream = $ft.offer(to, source, comment, @jid)
        
        if stream
          if confirm_acceptance_to
            send_msg(confirm_acceptance_to, _("File '%{file}' has been accepted by '%{user}'") % {:file => file.name, :user => to.to_s})
          end
          $log.info(">>") {"INIT #{file.path} - #{to.to_s} - #{@jid.to_s}"}
          if stream.kind_of?(Jabber::Bytestreams::SOCKS5Bytestreams)
              stream.add_streamhost($socks)
              ($conf['proxy'] || []).each { |proxy|
                stream.add_streamhost(proxy)
              }
          end
          stream.open

          while buf = source.read(0x1000)
            stream.write(buf)
            $out_bytes += buf.size
          end

          $out_files += 1
          $log.info(">>") {"DONE #{file.path} - #{to.to_s} - #{@jid.to_s}"}
          return true
        else
          $log.info(">>") {"ERR CONN #{file.path} - #{to.to_s} - #{@jid.to_s}"}
        end
      rescue Exception => e
        $log.info(">>") {"#{e}: #{e.backtrace.join("\n")}"}
      end
      return false
    end # }}}
  end
end

# vim: ts=2 sts=2 sw=2 foldmethod=marker et
