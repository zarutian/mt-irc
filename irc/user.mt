import "unittest" =~ [=> unittest]
exports (makeUser, sourceToUser)

def makeUser(nick :Str, user :Str, host :Str) as DeepFrozen:
    return object completeUser:
        to _printOn(out):
            out.print(`$nick!$user@@$host`)

        to _uncall():
            return [makeUser, [nick, user, host], [].asMap()]

        to getNick() :Str:
            return nick

        to getUser() :Str:
            return user

        to getHost() :Str:
            return host

def placeHolder()

def makeChannel(irc_conn :Any, name :Str) :Any
    def chanzens := [].asMap().diverge()
    
    return object irc_channel:
        to _printOn(out)
          out.print(`irc channel: $name`)
          
        to handle_JOIN(user :Any)
          chanzens[user] := placeHolder
          
        to handle_PART(user :Any, part_msg :Str)
          if (chanzens.contains(user))
            chanzens.removeKey(user)
            
        to handle_QUIT(user :Any, quit_msg :Str)
          if (chanzens.contains(user))
            chanzens.removeKey(user)

def makeExtendedUser(irc_conn :Any, nick_in :Str, user :Str, host :Str, handler_in :Any) :Any:
    var nick :Str := nick_in
    var handler :Any := handler_in
    var nickserv_identified :Bool := false
    def channels := [].asMap().diverge()
    return object extendedUser:
        to _printOn(out):
            out.print(`$nick!$user@@$host`)
            
        to _uncall():
            return null
            
        to getNick() :Str:
            return nick
        
        to getUser() :Str:
            return user
            
        to getHost() :Str:
            return host
            
        to handle_privmsg(dest :Str, msg :Str):
        
        to handle_CTCP(dest :Str, msg :Str):
        
        to handle_nick_change(new_nick :Str):
          nick := new_nick

def sourceToUser(specimen, ej) as DeepFrozen:
    switch (specimen):
        match `@nick!@user@@@host`:
            return makeUser(nick, user, host)
        match _:
            throw.eject(ej, "Could not parse source into user")

def testSourceToUser(assert):
    assert.ejects(fn ej {def via (sourceToUser) x exit ej := "asdf"})
    assert.doesNotEject(fn ej {def via (sourceToUser) x exit ej := "nick!user@host"})

unittest([testSourceToUser])
