#!/usr/bin/ruby
# -*- coding: utf-8 -*-

require 'optparse'
require 'socket'

port = nil
rawf = nil
skip = false
in_only = out_only = ltm_only = raw = false

ARGV.options do |opt|
  opt.banner = "#{File.basename($0)} [options] [file]"
  opt.on('-u','--udp PORT'){|o| port=o}
  opt.on('-i','--input') {in_only = true}
  opt.on('-o','--output') {out_only = true}
  opt.on('-l','--ltm') {ltm_only = true}
  opt.on('-r','--raw') {raw = true}
  opt.on('-s','--skip-first','skip any initial delay for udp') {skip = true}
  opt.on('-?', "--help", "Show this message") {puts opt.to_s; exit}
  begin
    opt.parse!
  rescue
    puts opt ; exit
  end
end

skt=nil
host=nil
lt = 0

if port
  if(m = port.match(/(\S+):(\d+)/))
    host = (m[1]||'localhost')
    port = m[2].to_i
  else
    port = port.to_i
    host = 'localhost'
  end
  addrs = Socket.getaddrinfo(host, port,nil,:DGRAM)
  skt = ((addrs[0][0] == 'AF_INET6') ? UDPSocket.new(Socket::AF_INET6) : UDPSocket.new)
end

if raw
  rawf = File.open("raw_dump.txt", 'w')
end

File.open(ARGV[0]) do |f|
  loop do
    s = f.read(10)
    break if s.nil?
    ts,len,dir=s.unpack('dCa')
    data = f.read(len)
    next if in_only && dir == "o"
    next if out_only && dir == "i"
    next if ltm_only && data[1] != 'T'
    puts "offset #{ts} len #{len} #{dir}"
    puts data.inspect
    data.each_byte do |b|
      STDOUT.printf "%02x ",b
    end
    puts
    if raw
      rawf.print data
    end

    if skt
      if data[1] == 'T'
	delta = ts-lt
	puts "Sleep #{delta}"
	sleep delta if skip == false or delta.zero?
	skip = false if(skip)
	skt.send data,0,host,port
      end
    end
    lt=ts
  end
end
if raw
  rawf.close
end