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

require 'mysql'

module JDisk
  class Database
    def initialize  # Otevre databazi {{{
      host = $conf['mysql_host']
      user = $conf['mysql_user']
      pwd = $conf['mysql_pwd']
      db = $conf['mysql_db']
      $db = Mysql.new(host, user, pwd, db)
      create_tables
      $db.query("UPDATE users SET allocated = 0 WHERE allocated <> 0")
      mysql_keep = Thread.new() do
        while true
          res = $db.query("SELECT 'a'")
          res.free
          sleep(5*60)
        end
      end 
    end # }}}
=begin rdoc
creates tabels - 
 * users
   * jid
   * gid - group_id
   * lang
   * aprox_used - filesystem usage
   * allocated
   * nastaveni
 * nodes
   * name
 * subscriptions
   * uid - user_id
   * nid - node_id
   * cwd
 * groups
   * nazev
   * quota
   * pattern
   * weight
 * suspicious
   * jid
   * file
 * filecomments
   * uid - user_id
   * nid - node_id
   * file
   * text
and view
 * limits
=end
    def create_tables # Pokud neexistuji, vytvori tabulky v databazi {{{
      $db.query("CREATE TABLE IF NOT EXISTS users (id INTEGER PRIMARY KEY AUTO_INCREMENT,
                                                   jid VARCHAR(128),
                                                   gid INTEGER,
                                                   lang VARCHAR(5),
                                                   aprox_used INTEGER,
                                                   allocated INTEGER,
                                                   nastaveni INTEGER)")

      $db.query("CREATE TABLE IF NOT EXISTS nodes (id INTEGER PRIMARY KEY AUTO_INCREMENT,
                                                   name VARCHAR(16))")

      $db.query("CREATE TABLE IF NOT EXISTS subscriptions (uid INTEGER,
                                                           nid INTEGER,
                                                           cwd VARCHAR(260) DEFAULT NULL,
                                                           PRIMARY KEY (uid, nid))")


      $db.query("CREATE TABLE IF NOT EXISTS groups (id INTEGER PRIMARY KEY AUTO_INCREMENT,
                                                    nazev VARCHAR(32),
                                                    quota INTEGER,
                                                    pattern VARCHAR(64),
                                                    weight INTEGER)")

      $db.query("CREATE TABLE IF NOT EXISTS suspicious (id INTEGER PRIMARY KEY AUTO_INCREMENT,
                                                        jid VARCHAR(128),
                                                        file VARCHAR(128))")

      $db.query("CREATE TABLE IF NOT EXISTS filecomments (id INTEGER PRIMARY KEY AUTO_INCREMENT,
                                                          uid INTEGER,
                                                          nid INTEGER,
                                                          file VARCHAR(128), 
                                                          comment VARCHAR(256))")

      $db.query("CREATE OR REPLACE VIEW limits AS SELECT u.jid AS jid,
                                                         u.id as uid,
                                                           u.allocated AS allocated,
                                                           u.aprox_used AS used,
                                                           g.nazev AS nazev,
                                                           g.quota AS quota,
                                                           g.weight AS weight
                                                    FROM users u, groups g
                                                    WHERE u.jid LIKE g.pattern")

      $db.query("INSERT IGNORE INTO groups VALUES (1, 'Obecna', 5*1024*1024, '%', 0)")

      update_01_02
    end # }}} 

    def update_01_02 # {{{ update from jdisk 0.1 database scheme to 0.2 scheme
      $db.query("SELECT cwd FROM subscriptions LIMIT 1")
    rescue Mysql::Error
      # add new column into subscriptions
      $db.query("ALTER TABLE subscriptions ADD COLUMN cwd VARCHAR(260) DEFAULT NULL")
      # 'delete' all set languages, in 0.2 changes the way of handling them
      $db.query("UPDATE users SET lang = NULL")
      # make absolute paths in db
      $db.query("UPDATE filecomments SET file = CONCAT('/', file)")
    end
  end
end

# vim: ts=2 sts=2 sw=2 foldmethod=marker et
