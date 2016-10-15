# Copyright (C) 2014 Google Inc. All rights reserved.
#
# Licensed under the Apache License, Version 2.0 (the "License"); you may not
# use this file except in compliance with the License. You may obtain a copy
# of the License at
#
# http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS, WITHOUT
# WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied. See the
# License for the specific language governing permissions and limitations
# under the License.

import "lib/codec/utf8" =~ [=> UTF8 :DeepFrozen]
import "lib/streams" =~ [
    => alterSink :DeepFrozen,
    => alterSource :DeepFrozen,
    => flow :DeepFrozen,
    => makePump :DeepFrozen,
]
import "irc/user" =~ [=> sourceToUser :DeepFrozen]
import "tokenBucket" =~ [=> makeTokenBucket :DeepFrozen]
exports (makeIRCConnector, makeIRCClient)

def makeIRCClient(handler, Timer, source, sink) as DeepFrozen:
    var nickname :Str := handler.getNick()
    # This hostname will be refined later as the IRC server gives us more
    # feedback on what our reverse hostname looks like.
    var hostname :Str := "localhost"
    def username :Str := "monte"
    var channels := [].asMap()

    # Pending events.
    def pendingChannels := [].asMap().diverge()

    # Freenode's official rules are 2 seconds per line (0.5 lines/second) and
    # 5 lines of burst. However, in practice, a refill rate of 0.5 appears to
    # be a little too fast; we're still getting rate-limited every so often
    # during long spans. So, instead, we're going to just lower the refill a
    # tad. ~ C.
    def tokenBucket := makeTokenBucket(5, 0.42)
    tokenBucket.start(Timer)

    def line(l :Str) :Void:
        traceln(`write($l) $tokenBucket`)
        when (tokenBucket.willDeduct(1)) ->
            traceln(`Sending line: $l`)
            sink(l + "\r\n")

    # PRIVMSG/NOTICE common core.
    def sendMsg(type :Str, channel :Str, var message :Str):
        def msg := `$type $channel :`
        # ` nick!user@host `
        def sourceLen := 4 + username.size() + nickname.size() + hostname.size()
        # XXX WTF do these numbers come from? They're not obvious. Could we
        # use msg.size() instead?
        def paddingLen := 6 + 6 + 3 + 2 + 2
        # Not 512, because \r\n is 2 and will be added by line().
        def availableLen := 510 - sourceLen - paddingLen
        while (message.size() > availableLen):
            def slice := message.slice(0, availableLen)
            def i := slice.lastIndexOf(" ")
            def snippet := slice.slice(0, i)
            line(msg + snippet)
            message slice= (i + 1)
        line(msg + message)

    # Login.

    line(`NICK $nickname`)
    line(`USER $username $hostname irc.freenode.net :Monte`)
    line("PING :suchPing") 

    object IRCClient extends sink:
        # Override the sink to hook in behavior.
        to run(item):
            switch (item):
                match `:@{via (sourceToUser) user} PRIVMSG @channel :@message`:
                    if (message[0] == '\x01'):
                        # CTCP.
                        handler.ctcp(IRCClient, user,
                                     message.slice(1, message.size() - 1))
                    else:
                        handler.privmsg(IRCClient, user, channel, message)

                match `:@{via (sourceToUser) user} JOIN @channel`:
                    def nick := user.getNick()
                    if (nickname == nick):
                        # This is pretty much the best way to find out what
                        # our reflected hostname is.
                        def host := user.getHost()
                        traceln(`Refined hostname from $hostname to $host`)
                        hostname := host

                        IRCClient.joined(channel)
                    # We have to call joined() prior to accessing this map.
                    channels[channel][nick] := []
                    traceln(`$nick joined $channel`)

                match `:@nick!@{_} QUIT @{_}`:
                    for channel in (channels):
                        if (channel.contains(nick)):
                            channel.removeKey(nick)
                    traceln(`$nick has quit`)

                match `:@nick!@{_} PART @channel @{_}`:
                    if (channels[channel].contains(nick)):
                        channels[channel].removeKey(nick)
                    traceln(`$nick has parted $channel`)

                match `:@nick!@{_} PART @channel`:
                    if (channels[channel].contains(nick)):
                        channels[channel].removeKey(nick)
                    traceln(`$nick has parted $channel`)

                match `:@oldNick!@{_} NICK :@newNick`:
                    for channel in (channels):
                        escape ej:
                            def mode := channel.fetch(oldNick, ej)
                            channel.removeKey(oldNick)
                            channel[newNick] := mode
                    traceln(`$oldNick is now known as $newNick`)

                match `PING @ping`:
                    IRCClient.pong(ping)

                # XXX @_
                match `:@{_} 004 $nickname @hostname @version @userModes @channelModes`:
                    traceln(`Logged in as $nickname!`)
                    traceln(`Server $hostname ($version)`)
                    traceln(`User modes: $userModes`)
                    traceln(`Channel modes: $channelModes`)
                    handler.loggedIn(IRCClient)

                match `@{_} 353 $nickname @{_} @channel :@nicks`:
                    def channelNicks := channels[channel]
                    def nickList := nicks.split(" ")
                    for nick in (nickList):
                        channelNicks[nick] := null
                    traceln(`Current nicks on $channel: $channelNicks`)

                match _:
                    traceln(item)

        # Call these to make stuff happen.

        to pong(ping):
            line(`PONG $ping`)

        to part(channel :Str, message :Str):
            line(`PART $channel :$message`)

        to quit(message :Str):
            for channel => _ in (channels):
                IRCClient.part(channel, message)
            line(`QUIT :$message`)
            tokenBucket.stop()

        to join(var channel :Str):
            if (channel[0] != '#'):
                channel := "#" + channel
            line(`JOIN $channel`)

        to say(channel, message):
            sendMsg("PRIVMSG", channel, message)

        to notice(channel, var message):
            sendMsg("NOTICE", channel, message)

        to ctcp(nick, message):
            # XXX CTCP quoting
            IRCClient.notice(nick, `$\x01$message$\x01`)

        # Data accessors.

        to getUsers(channel, ej):
            return channels.fetch(channel, ej)

        # Low-level events.

        to joined(channel :Str):
            traceln(`I joined $channel`)
            channels with= (channel, [].asMap().diverge())

            if (pendingChannels.contains(channel)):
                pendingChannels[channel].resolve(null)
                pendingChannels.removeKey(channel)

        # High-level events.

        to hasJoined(channel :Str) :Vow[Void]:
            return if (channels.contains(channel)):
                null
            else:
                IRCClient.join(channel)
                def [p, r] := Ref.promise()
                pendingChannels[channel] := r
                return p

    flow(source, IRCClient)
    return IRCClient

def makeLinePump() as DeepFrozen:
    return makePump.splitAt(b`$\r$\n`, b``)

def makeIRCConnector(handler, Timer) as DeepFrozen:
    return object IRCConnection:
        to connect(endpoint) :Vow:
            def [epSource, epSink] := endpoint.connectStream()
            return when (epSource, epSink) ->
                def lineSource := alterSource.fusePump(makeLinePump(), epSource)
                def source := alterSource.decodeWith(UTF8, lineSource)
                def sink := alterSink.encodeWith(UTF8, epSink)

                makeIRCClient(handler, Timer, source, sink)
