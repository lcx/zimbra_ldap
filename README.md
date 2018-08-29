# Introduction

This script allows to copy contacts form zimbra to a ldap server which can be
used for a snom phone for example to display the contact name when receiving a
call.

## Prerequisites

You need an ldap server and the zimbra preauth token for the domain of which
you want to access a users contacts.
See [Zimbra Wiki](https://wiki.zimbra.com/wiki/Preauth) on how to create the
preauth token.

## Known restrictions

It's slow as I have not found a way to drop existing data other then deleting
one by one.

## CallerID instead of name is being displayed after pickup.

If you have an issue that you the name is gone once you pick up the phone and
it displays the callerID again (happens with snom phone) then set the
caller_id_name to `_undef_`, in freeswitch:

```
action set effective_caller_id_name=_undef_
```

See [Freeswtich conflence](https://freeswitch.org/confluence/display/FREESWITCH/effective_caller_id_name)
