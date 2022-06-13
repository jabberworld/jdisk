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
  class Fake_DUser
    attr_reader :lang
    attr_reader :jid
    attr_reader :full_jid

    def initialize(jid, msg_lang = nil)
      @full_jid = Jabber::JID.new(jid)
      @jid = @full_jid.strip
      @lang = msg_lang
    end
  end

  class DUser

    attr_reader :did      # Database ID
    attr_reader :jid      # Jabber ID (bare)
    attr_reader :full_jid # Jabber ID (bare/resource)
    attr_reader :lang     # User language

    def initialize(jid, msg_lang = nil)
      @full_jid = Jabber::JID.new(jid)
      @jid = @full_jid.strip
      @lang = msg_lang

      res = $db.query("SELECT id, lang
                       FROM users
                       WHERE jid='#{$db.quote(@jid.to_s)}'")
      unless res.nil?
        if result = res.fetch_row
          @did = result[0]
          @lang = result[1] unless result[1].nil?
        else
          @did = nil
        end
        res.free
      end

      if @did.nil?
        $db.query("INSERT INTO users (jid, gid, allocated, lang, nastaveni)
                   VALUES ('#{$db.quote(@jid.to_s)}', NULL, 0, NULL, 0)")
        @did = $db.insert_id
      end
    end # }}}

    
    def DUser.exist?(jid) # Zjisti zda existuje zadany uzivatel {{{
      return false if jid.nil?
      jid = Jabber::JID.new(jid).strip.to_s # Strip resource in any case
      res = $db.query("SELECT id FROM users WHERE jid='#{$db.quote(jid)}'")
      return false if res.nil?
      result = res.num_rows > 0
      res.free

      return result
    end # }}}

    def alloc(bytes) # Zjisti jestli se to po uploadu [bytu] bytu dat vejde do limitu uzivatele a misto predbezne alokuje {{{
      if (bytes < 0) || ((res = get_space) && ((res[0] + bytes) <= res[1]))
        $db.query("UPDATE users SET allocated = allocated + #{bytes} WHERE id='#{@did}'")
        return true
      end
      return false
    end # }}}
    
    def remove # Odstrani zadaneho uzivatele {{{
      $db.query("DELETE FROM users WHERE id=#{@did}")
      $db.query("DELETE FROM file_comments WHERE uid=#{@did}")
    end # }}} 

    def get_used_stats(exact=true, brief=false) # Navrati velikost obsazeneno mista {{{
      if brief == true
        str = "%{used} / %{total} used, %{avail} free"
      else
        str = "Using %{used} of %{total}. Still available: %{avail}. Allocated for upload: %{res}."
      end

      if res = get_space(exact)
        _(str) %
        {:used => res[0].to_file_size,
         :total => res[1].to_file_size,
         :avail => (res[1] - res[0]).to_file_size,
         :res => res[2].to_file_size}
      end
    end # }}}

    def lang=(msg_lang)
      @lang = msg_lang
      if @lang
        $db.query("UPDATE users SET lang = '#{$db.quote(@lang)}' WHERE id='#{@did}'")
      else
        $db.query("UPDATE users SET lang = NULL WHERE id='#{@did}'")
      end
    end

    def update_status(size = nil, delta = nil) # {{{
      if size
        if delta
          # Update DB field
          query = "UPDATE users SET aprox_used = aprox_used + '#{$db.quote(size.to_s)}' WHERE id='#{@did}'"
        else
          query = "UPDATE users SET aprox_used = '#{$db.quote(size.to_s)}' WHERE id='#{@did}'"
        end
      end

      $db.query(query)
    end #}}}

    def send_presence(presence)
      $nodes.each do |k,node|
        node.send_presence(self, presence) if node.subscribed(self)
      end
    end

  private 
    
    def get_used_space # Count used space on disk {{{
       size = 0
       $nodes.each_value do |v|
         size += v.get_used_space(self)
       end

       size
    end # }}}

    def get_space(exact=true) # Navrátí obsazené místo a quotu pro dané jid {{{
      query = "SELECT allocated, quota, used" +
              "  FROM limits l" +
              "  WHERE uid='#{@did}' ORDER BY weight DESC"
      res = $db.query(query)

      return false if res.nil?
      result = false
      if row = res.fetch_row
        result = []
        result[2] = row[0].to_i
        result[0] = row[2].to_i + result[2]
        result[1] = row[1].to_i

        if exact
          result[0] = get_used_space + result[2]
          update_status(result[0], false)
        end

        $plugins.each do |plug|
          if plug.respond_to?("hook_disk_size")
            result[1] = plug.hook_disk_size(jid, result[1])
          end
        end
      end

      res.free
      return result
    end # }}}
  end
end

# vim: ts=2 sts=2 sw=2 foldmethod=marker et
