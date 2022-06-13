#!/usr/bin/ruby
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
  JDISK_VERSION = "0.2"
end

require 'logger'
require 'xmpp4r'
require 'xmpp4r/version/helper/simpleresponder'
require 'xmpp4r/bytestreams'
require 'xmpp4r/discovery'
require 'xmpp4r/vcard'
require 'fileutils'
require 'yaml'
require 'timeout'
require 'uri'
require 'zlib'
require 'shellwords'

require 'l10n'
require 'node'
require 'user'
require 'group'
require 'file'
require 'commands'
require 'database'

class Numeric
  def to_file_size  # returns number in file size units {{{
    kmg = ['', 'Ki', 'Mi', 'Gi', 'Ti', 'Pi', 'Ei']
    index = 0
    size = self.to_f
    while size >= 1024
      size /= 1024
      index += 1
    end
    index == 0 ? "#{size.to_i}B" : ("%.1f#{kmg[index]}B" % size)
  end # }}}
end

module Jabber
  class XMPPStanza
    def lang
      (a = attribute('lang')).nil? ? a : a.value
    end

    def lang=(v)
      add_attribute('xml:lang', v.to_s)
    end
  end
end

module JDisk
  class Disk
    attr_accessor :online
    
=begin rdoc
Starts the jabber disk.
sets following global variables
$in_bytes, $out_bytes, $in_files, $out_files, $log, $plugins, $ddb (points to our database), $c (jabber component)
$sock, $conf, $ft, $incoming, $nodes
=end
    def initialize # Pripojeni k serveru a nastaveni callbacku {{{
      $log = Logger.new(STDOUT)
      $log.level = Logger::INFO
      @start_time = Time.now
      @online = 0
      $in_bytes = 0
      $out_bytes = 0
      $in_files = 0
      $out_files = 0
      @online_users = {}

      @identities = [Jabber::Discovery::Identity::new('store', 'Filestore - Jabber Disk', 'file')]
      @features = [Jabber::Discovery::Feature::new("http://jabber.org/protocol/bytestreams"),
                  Jabber::Discovery::Feature::new("http://jabber.org/protocol/si"),
                  Jabber::Discovery::Feature::new("http://jabber.org/protocol/si/profile/file-transfer"),
                  Jabber::Discovery::Feature::new("jabber:iq:register"),
                  Jabber::Discovery::Feature::new("http://jabber.org/protocol/disco#info"),
                  Jabber::Discovery::Feature::new("http://jabber.org/protocol/disco#items"),
                  Jabber::Discovery::Feature::new("http://jabber.org/protocol/stats")]
 
      $caps = Jabber::Caps::C.new("http://dev.jabbim.cz/jdisk/#{JDISK_VERSION}", Jabber::Caps::generate_ver(@identities, @features))

      $log.info {"Loading plugins"}

      $plugins = []
      Dir['plug_*.rb'].each do |filename|
        load filename
      end

      $log.info {"Initialization of the user database"}

      $ddb = JDisk::Database.new
      
      $log.info {"Connecting to the server"}
      
      $c = Jabber::Component.new($conf['name'])
      $c.connect($conf['host'], $conf['port'])
      $c.auth($conf['pass'])

      @mainThread = Thread.current
    
      $c.on_exception do |e, conn, where|
        $log.fatal {"Exception from connection: #{e}: #{e.backtrace.join("\n")}, GOING DOWN!"}
        @mainThread.wakeup
      end

      $log.info {"Creating classes for filetransfers"}
        
      $socks = Jabber::Bytestreams::SOCKS5BytestreamsServer.new($conf['socks_port'])
      $socks.add_address($conf['socks_addr'])

      $ft = Jabber::FileTransfer::Helper.new($c)

      $log.info {"Callback registration"}
  
      # add some version info :)
      Jabber::Version::SimpleResponder.new($c, "JabberDisk", JDISK_VERSION, "Windows Server 2008")
      
      $ft.add_incoming_callback { |iq,file|
        incoming_callback(iq,file)
      }

      $c.add_message_callback { |msg|
        message_callback(msg)
      }

      $c.add_iq_callback { |iq|
        iq_callback(iq)
      }

      $c.add_presence_callback{ |pres|
        presence_callback(pres)
      }

      $incoming = {}
      $nodes = {}
      $conf['nodes'].each_key do |k|
        $nodes[k] = DNode.new(k)
      end

      # Send presence to subscribed users
      $nodes.each_value do |node|
        node.subscribed do |user|
          duser = DUser.new(user)
          pres = duser.get_used_stats(exact = false, brief = true)
          node.send_presence(duser, pres)
        end
      end

      Thread.stop
      $>.flush
      $c.close
    end # }}}

    def incoming_callback(iq,file) # Callback zavolany pri prichozim souboru {{{
      node = $nodes[iq.to.node]
      if node
        if DUser.exist?(iq.from)
          node.incoming_file(iq, file)
        else
          $log.info("<<") {"DENY #{iq.from.strip.to_s} - #{iq.to.node.to_s} - #{file.fname}"}
          node.send_msg(iq.from, _("You are not registered with this service"))
          $ft.decline(iq)
        end
      else
        $ft.decline(iq)
      end
    rescue Exception => e
      $log.error {"#{e}: #{e.backtrace.join("\n")}"}
    end # }}}

    def message_callback(msg) # {{{
      return if msg.type == :error
      Thread.new do
        begin
          $log.info("<M") {"MSG(#{msg.to.node}) #{msg.from.to_s} - #{msg.body} -- #{msg.lang}"}
          disk_node = $nodes[msg.to.node]

          unless DUser.exist?(msg.from)
            disk_node.send_msg(msg.from, _("You are not registered with this service"))
          else
            user = DUser.new(msg.from, msg.lang)
            unless msg.body.nil? || disk_node.nil?
              begin
                mess = Shellwords.shellwords(msg.body)
                command = mess.shift
                if respond_to?('cmd_'+command)
                  output = send('cmd_'+command, mess, disk_node, user) || []
                else
                  output = cmd_help(mess, disk_node, user)
                end
              rescue ArgumentError => e
                output = e.to_s
              end
              disk_node.send_msg(user, output) unless output.empty?
            end
          end
        rescue Exception => e
          $log.error {"#{e}: #{e.backtrace.join("\n")}"}
        end
      end
    end # }}}

    def iq_callback(iq) # {{{
      return if iq.type == :error
      if iq.query
        if iq.query.kind_of?(Jabber::Discovery::IqQueryDiscoInfo) || iq.query.kind_of?(Jabber::Discovery::IqQueryDiscoItems)
          iq_query_disco(iq)
        elsif iq.query.namespace == 'jabber:iq:register'
          if iq.type == :get
            iq_register_get(iq)
          elsif iq.type == :set
            iq_register_set(iq)
          end
        elsif iq.query.namespace == 'http://jabber.org/protocol/stats'
          iq_stats(iq)
        else
          iq.to, iq.from = iq.from, iq.to
          iq.type = :error
          iq.add(Jabber::ErrorResponse.new('not-acceptable'))
          $c.send(iq)
        end
      elsif iq.vcard && iq.vcard.kind_of?(Jabber::Vcard::IqVcard)
        iq_query_vcard(iq)
      else
        iq.to, iq.from = iq.from, iq.to
        iq.type = :error
        iq.add(Jabber::ErrorResponse.new('feature-not-implemented'))
        $c.send(iq)
      end
    rescue Exception => e
      $log.error {"#{e}: #{e.backtrace.join("\n")}"}
    end # }}}

    def iq_query_vcard(iq) # Handles Vcard request {{{
      iq.from, iq.to = iq.to, iq.from
      iq.type = :result
      if ['public', 'private', 'album'].include?(iq.from.node.to_s)
        filename = "icons/jdisk-#{iq.from.node.to_s}.png"
      else
        filename = "icons/jdisk.png"
      end
      iq.vcard['PHOTO/TYPE'] = 'image/png'
      iq.vcard['PHOTO/BINVAL'] = [IO.read(filename)].pack("m")
      $c.send(iq)
    end # }}}

    def iq_query_disco(iq) # Handles disco information {{{
      iq.from, iq.to = iq.to, iq.from
      iq.type = :result
      caps = $caps.node + "#" + $caps.ver

      if iq.query.kind_of?(Jabber::Discovery::IqQueryDiscoInfo)
        if iq.from.to_s == $c.jid.to_s
            iq.query.add(Jabber::Discovery::Identity::new('store', 'Filestore - Jabber Disk', 'file'))
            iq.query.add(Jabber::Discovery::Feature::new("jabber:iq:register"))
            iq.query.add(Jabber::Discovery::Feature::new("http://jabber.org/protocol/stats"))
        end

        unless ['.', '/', caps].include?(iq.query.node)
          iq.query.add(Jabber::Discovery::Feature::new("http://jabber.org/protocol/disco#info"))
          iq.query.add(Jabber::Discovery::Feature::new("http://jabber.org/protocol/disco#items"))
        end
        if iq.query.node == caps || ($nodes.has_key?(iq.from.node.to_s) && (iq.query.node == '/' || iq.query.node.nil?))
          @identities.each do |identity|
            iq.query.add(identity)
          end
          @features.each do |feature|
            iq.query.add(feature)
          end
        end
      # IqQueryDiscoItems
      elsif iq.query.node == 'http://jabber.org/protocol/commands'
        # return error as response to command list node, even when we don't advertise this feature, some 'broken' clients may send it
        iq.type = :error
        iq.add(Jabber::ErrorResponse.new('feature-not-implemented'))
      else
        if iq.from.to_s == $c.jid.to_s
          $nodes.each_key do |k|
            iq.query.add(Jabber::Discovery::Item::new(k+'@'+$c.jid.to_s, $nodes[k].name, "/"))
          end
        elsif $nodes.has_key?(iq.from.node)
           path = iq.query.node
           if path && path != '.'
            $nodes[iq.from.node].gad(DUser.new(iq.to, iq.lang), path).list do |file|
              iq.query.add(
                Jabber::Discovery::Item::new(
                  iq.from.node+'@'+$c.jid.to_s,
                  "#{file.name} [#{file.directory? ? 'DIR' : file.size.to_file_size}]",
                  file.directory? ? file.path : "."))
            end
          end
        end
      end
      $c.send(iq)
    end # }}}

    def iq_register_get(iq) # {{{
      iq.from, iq.to = iq.to, iq.from
      iq.type = :result
      if(DUser.exist?(iq.to))
        iq.query.add(REXML::Element.new("registered"))
      end
      instructions = REXML::Element.new("instructions")

      lang = iq.lang == "" or iq.lang == nil ? nil : iq.lang.to_sym
      i_text = cmd_intro(nil, nil, Fake_DUser.new(iq.to, iq.lang))
      i_text = i_text.translate(lang) if i_text.kind_of?(Array)
      i_text = i_text.get_translation(lang) if i_text.kind_of?(LString)

      instructions.text = i_text
      iq.query.add(instructions)
      $c.send(iq)
    end # }}}

    def iq_register_set(iq) # {{{
      return unless $nodes.has_key?(iq.to.node) || iq.to.to_s == $c.jid.to_s
      iq_ans = iq.answer(false)
      if iq.query.first_element('remove')       # Unregister?
        iq_ans.type = :error
        iq_ans.add(Jabber::ErrorResponse.new('not-authorized'))
        $c.send(iq_ans)
      else                                # Register
        iq_ans.type = :result
        $c.send(iq_ans)
        user = DUser.new(iq.from, iq.lang)
        if iq.to.strip.to_s == $c.jid.to_s
          $nodes.each do |k,node|
            node.set_subscribed(user, true)
            node.send_presence(user, nil, :subscribe)
          end
          
        else
          node = $nodes[iq.to.node]
          node.set_subscribed(user, true)
          node.send_presence(user, nil, :subscribe)
        end
      end
    end # }}}

    def iq_stats(iq) # {{{
      iq.from, iq.to  = iq.to, iq.from
      iq.type = :result
      stats = false
      iq.elements.each('*/stat') do |elem|
        stats = true
        case elem.attributes["name"]
          when 'time/uptime' 
            elem.attributes["units"] = 'seconds' 
            elem.attributes["value"] = (Time.now - @start_time).to_i.to_s 
          when 'users/online'
            elem.attributes["units"] = 'users'
            elem.attributes["value"] = @online_users.length
          when 'bandwidth/bytes-in'
            elem.attributes["units"] = 'bytes'
            elem.attributes["value"] = $in_bytes
          when 'bandwidth/bytes-out'
            elem.attributes["units"] = 'bytes'
            elem.attributes["value"] = $out_bytes
          when 'bandwidth/files-in' 
            elem.attributes["units"] = 'files' 
            elem.attributes["value"] = $in_files 
          when 'bandwidth/files-out' 
            elem.attributes["units"] = 'files' 
            elem.attributes["value"] = $out_files
        end
      end

      unless stats
        ["time/uptime", "users/online", 
          "bandwidth/bytes-in", "bandwidth/bytes-out", 
          "bandwidth/files-in", "bandwidth/files-out"].each do |attr| 
          el = REXML::Element.new("stat") 
          el.attributes["name"] = attr 
          iq.query.add(el) 
        end 
      end
      $c.send(iq)
    end # }}}

    def presence_callback(pres) # {{{
      return unless $nodes.has_key?(pres.to.node)

      node = $nodes[pres.to.node]
      user = DUser.new(pres.from, pres.lang)

      case pres.type
        when :probe
          if(node.subscribed(user))
            pres = user.get_used_stats(exact = false, brief = true)
            node.send_presence(user, pres)
            @online_users[user.jid] = true
          end
        when :unavailable
          @online_users.delete(user.jid)
        when :subscribe
          node.set_subscribed(user, true)
          pres = user.get_used_stats(exact = false, brief = true)

          node.send_presence(user, nil, :subscribed)
          node.send_presence(user, pres)
        when :unsubscribe
          node.set_subscribed(user, false)
          node.send_presence(user, nil, :unsubscribed)
      end
    rescue Exception => e
      $log.error {"#{e}: #{e.backtrace.join("\n")}"}
    end # }}}
  end

  $>.sync = true
  $conf = YAML::load File.new('jdisk.conf')

  L10N.new
  Disk.new
end

# vim: ts=2 sts=2 sw=2 foldmethod=marker et 
