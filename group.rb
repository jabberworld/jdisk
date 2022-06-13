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
  class DGroup
    attr_reader :did
    attr_reader :name

    def initialize(name)
      @name = name
      res = $db.query("SELECT id
                       FROM groups
                       WHERE nazev = '#{$db.quote(@name)}'")
      unless res.nil?
        @did = (result = res.fetch_row) ? result.first : nil
        res.free
      end

      if @did.nil?
        $db.query("INSERT INTO groups (nazev, quota, pattern, weight) VALUES ('#{$db.quote(@name)}', 0, '%', 0)")
        @did = $db.insert_id
      end
    end

    def get(column)
      res = $db.query("SELECT #{column.to_s} FROM groups WHERE id=#{@did}")
      result = nil
      unless res.nil?
        result = res.fetch_row.first
        res.free
      end
      result
    end

    def set(column, value)
      $db.query("UPDATE groups SET #{column.to_s}=#{value} WHERE id=#{@did}")  # QUOTE?
    end

    def pattern
      get(:pattern)
    end

    def pattern=(pat)
      set(:pattern, "'#{pat}'")
    end

    def quota
      get(:quota)
    end

    def quota=(quota)
      set(:quota, quota)
    end

    def weight
      get(:weight)
    end

    def weight=(weight)
      set(:weight, weight)
    end

    def members(nazev) # Navrati uzivatele patrici do zadane skupiny {{{
      query = "SELECT jid
               FROM limits
               WHERE nazev = '#{$db.quote(nazev)}'"
      res = $db.query(query)
      return if res.nil?

      res.each do |row|
        yield row[0]
      end
      res.free
    end # }}} 

    def DGroup.list # Pres yield vypise uzivatelske skupiny a jejich quoty {{{
      res = $db.query("SELECT nazev, pattern, weight, quota FROM groups")
      return if res.nil?
      
      res.each do |row|
        yield(row[0], row[1], row[2], row[3])
      end
      res.free
    end # }}} 
  end
end

# vim: ts=2 sts=2 sw=2 foldmethod=marker et
