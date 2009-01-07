# HttpdCoro - Httpd Protocol worker with coroutines
#
# This differs from HttpdSingle and HttpdThread, in that
# it integrates directly with the Httpd namespace, using coroutines
# to parse requests and handle responses.

proc bgerror {error eo} {
    Debug.error {Worker Error: $error ($eo)}
}

interp bgerror {} ::bgerror

interp alias {} armour {} string map {& &amp; < &lt; > &gt; \" &quot; ' "&#39;"}

proc HttpdWorker {args} {
    puts stderr "WOE: [info level -1] / [uplevel 1 [list namespace current]]"
}

package require WubUtils
package require spiders
package require Debug
Debug off HttpdCoro 10

package require Url
package require Http
package require Cookies
package require UA

package provide HttpdCoro 1.0

# import the relevant commands
namespace eval ::tcl::unsupported {namespace export coroutine yield infoCoroutine}
namespace import ::tcl::unsupported::coroutine ::tcl::unsupported::yield ::tcl::unsupported::infoCoroutine

namespace eval Httpd {
    variable generation		;# worker/connection association generation

    # limits on header size
    variable maxline 2048	;# max request line length
    variable maxfield 4096	;# max request field length
    variable maxhead 1024	;# maximum number of header lines
    variable maxurilen 1024	;# maximum URI length
    variable maxentity -1	;# maximum entity size

    variable txtime 20000	;# inter-write timeout
    variable rxtime 10000	;# inter-read timeout
    variable enttime 10000	;# entity inter-read timeout

    # timeout - by default none
    variable rxtimeout 60000

    # arrange gzip Transfer Encoding
    if {![catch {package require zlib}]} {
	variable ce_encodings {gzip}
    } else {
	variable ce_encodings {}
    }
    #set ce_encodings {}	;# uncomment to stop gzip transfers
    variable te_encodings {chunked}

    variable uniq [pid]	;# seed for unique coroutine names

    # give a uniq looking name
    proc uniq {} {
	variable uniq
	return [incr uniq]
    }

    # wrapper for chan ops - alert on errors
    proc chan {args} {
	set code [catch {uplevel 1 ::chan $args} e eo]
	if {$code} {
	    if {[info coroutine] ne ""} {
		Debug.HttpdCoro {[info coroutine]: chan error $code - $e ($eo)}
		EOF $e	;# clean up and close
	    } else {
		Debug.error {chan error $code - $e ($eo)}
	    }
	} else {
	    return $e
	}
    }

    # indicate EOF and shut down socket and reader
    proc EOF {{reason ""}} {
	Debug.HttpdCoro {[info coroutine] EOF: ($reason)}

	# forget whatever higher level connection info
	corovars cid socket consumer timer

	# cancel all outstanding timers for this coro
	foreach t $timer {
	    catch {
		after cancel $t	;# cancel old timer
	    } e eo
	    Debug.HttpdCoro {cancel [info coroutine] $t - $e ($eo)}
	}

	if {[catch {forget $cid} e eo]} {
	    Debug.error {EOF forget error '$e' ($eo)}
	}

	# report EOF to consumer if it's still alive
	if {[info commands $consumer] eq ""} {
	    Debug.HttpdCoro {reader [info coroutine]: consumer gone on EOF}
	} elseif {[catch {
	    after 1 [list catch [list $consumer [list EOF $reason]]]
	    Debug.HttpdCoro {reader [info coroutine]: informed $consumer of EOF}
	} e eo]} {
	    Debug.error {reader [info coroutine]: consumer error on EOF $e ($eo)}
	}

	# clean up socket - the only point where we close
	chan close $socket

	# destroy reader - that's all she wrote
	Debug.HttpdCoro {reader [info coroutine]: suicide on EOF}
	return -level [info level] EOF	;# terminate coro
	#error EOF
    }

    # close? - should we close this connection?
    proc close? {r} {
	# don't honour 1.0 keep-alives - why?
	set close [expr {[dict get $r -version] < 1.1}]
	Debug.HttpdCoro {version [dict get $r -version] implies close=$close}

	# handle 'connection: close' request from client
	foreach ct [split [Dict get? $r connection] ,] {
	    if {[string tolower [string trim $ct]] eq "close"} {
		Debug.close {Tagging close at connection:close request}
		set close 1
		break	;# don't need to keep going
	    }
	}

	if {$close} {
	    # we're not accepting more input
	    # but defer closing the socket until all pending transmission's complete
	    corovars status closing socket
	    set closing 1	;# flag the closure
	    lappend status CLOSING
	    chan event $socket readable [list [info coroutine] CLOSING]
	}

	return $close
    }

    # rdump - return a stripped request for printing
    proc rdump {req} {
	dict set req -content <ELIDED>
	dict set req -entity <ELIDED>
	dict set req -gzip <ELIDED>
	return $req
    }

    # we have been told we can write a reply
    proc write {r cache} {
	corovars replies response sequence consumer generation satisfied transaction closing unsatisfied socket

	if {$closing && ![dict size $unsatisfied]} {
	    # we have no more requests to satisfy and we want to close
	    EOF "finally close"
	}

	if {[dict exists $r -suspend]} {
	    return 0	;# this reply has been suspended - we haven't got it yet
	}

	Debug.HttpdCoro {write [info coroutine] ([rdump $r]) satisfied: ($satisfied) unsatisfied: ($unsatisfied)}

	# fetch transaction from the caller's identity
	if {![dict exists $r -transaction]} {
	    # can't Send reply: no -transaction associated with request
	    Debug.error {Send discarded: no transaction ($r)}
	    return 1	;# close session
	}
	set trx [dict get $r -transaction]

	# discard duplicate responses
	if {[dict exists $satisfied $trx]} {
	    # a duplicate response has been sent - discard this
	    # this could happen if a dispatcher sends a response,
	    # then gets an error.
	    Debug.error {Send discarded: duplicate ([rdump $r])}
	    return 0	;# duplicate response - just ignore
	}

	# wire-format the reply transaction - messy
	variable ce_encodings	;# what encodings do we support?
	lassign [Http Send $r -cache $cache -encoding $ce_encodings] r header content empty cache
	set header "HTTP/1.1 $header" ;# add the HTTP signifier

	# global consequences - botting and caching
	if {![Honeypot newbot? $r] && $cache} {
	    # handle caching (under no circumstances cache bot replies)
	    Debug.HttpdCoro {Cache put: $header}
	    Cache put $r	;# cache it before it's sent
	}

	# record transaction reply and kick off the responder
	# response has been collected and is pending output
	# queue up response for transmission
	#
	# response is broken down into:
	# header - formatted to go down the line in crlf mode
	# content - content to go down the line in binary mode
	# close? - is the connection to be closed after this response?
	# chunked? - is the content to be sent in chunked mode?
	# empty? - is there actually no content, as distinct from 0-length content?
	Debug.HttpdCoro {ADD TRANS: $header ([dict keys $replies])}
	dict set replies $trx [list $header $content [close? $r] $empty]

	# send all responses in sequence from the next expected to the last available
	Debug.HttpdCoro {pending to send: [dict keys $replies]}
	foreach next [lsort -integer [dict keys $replies]] {
	    if {[chan eof $socket]} {
		# detect socket closure ASAP in sending
		Debug.HttpdCoro {Lost connection on transmit}
		return 1	;# socket's gone - terminate session
	    }

	    # ensure we don't send responses out of sequence
	    if {$next != $response} {
		# something's blocking the response pipeline
		# so we don't have a response for the next transaction.
		# we must therefore wait until all the preceding transactions
		# have something to send
		Debug.HttpdCoro {no pending or $next doesn't follow $response}
		return 0
	    }

	    # only send for unsatisfied requests
	    if {[dict exists $unsatisfied $trx]} {
		dict unset unsatisfied $trx	;# forget the unsatisfied status
	    } else {
		Debug.error {Send discarded: uduplicate ([rdump $r])}
		continue	;# duplicate response - just ignore
	    }

	    # respond to the next transaction in trx order
	    # unpack and consume the reply from replies queue
	    # remove this response from the pending response structure
	    lassign [dict get $replies $next] head content close empty
	    dict unset replies $next		;# consume next response
	    set response [expr {1 + $next}]	;# move to next response

	    # connection close required?
	    # NB: we only consider closing if all pending requests
	    # have been satisfied.
	    if {$close} {
		# inform client of intention to close
		Debug.close {close requested on $socket - sending header}
		append head "Connection: close" \r\n	;# send a close just in case
		# Once this header's been sent, we're committed to closing
	    }

	    # send headers with terminating nl
	    chan puts -nonewline $socket "$head\r\n"
	    Debug.HttpdCoro {SENT HEADER: $socket $head} 4

	    # send the content/entity (if any)
	    # note: we must *not* send a trailing newline, as this
	    # screws up the content-length and confuses the client
	    # which doesn't then pick up the next response
	    # in the pipeline
	    if {!$empty} {
		chan puts -nonewline $socket $content	;# send the content
		Debug.HttpdCoro {SENT ENTITY: [string length $content] bytes} 8
	    }
	    chan flush $socket
	    dict set satisfied $trx {}	;# record satisfaction of transaction

	    if {$close} {
		return 1	;# terminate session on request
	    }
	}

	return 0
    }

    # send --
    #	deliver in-sequence transaction responses
    #
    # Arguments:
    #
    # Side Effects:
    #	Send transaction responses to client
    #	Possibly close socket
    proc send {r {cache 1}} {
	Debug.HttpdCoro {send: ([rdump $r]) $cache}

	# check generation
	corovars generation
	if {[dict get $r -generation] != $generation} {
	    Debug.error {Send discarded: out of generation ($r)}
	    return ERROR	;# report error to caller
	}

	if {[catch {
	    # send all pending responses, ensuring we don't send out of sequence
	    write $r $cache
	} close eo]} {
	    Debug.error {FAILED send $close ($eo)}
	    set close 1
	} else {
	    Debug.HttpdCoro {SENT (close: $close)} 10
	}

	# deal with socket
	if {$close} {
	    EOF closed
	}
    }

    # yield wrapper with command dispatcher
    proc yield {{retval ""}} {
	corovars timer timeout cmd consumer status unsatisfied socket

	set time $timeout
	while {1} {
	    Debug.HttpdCoro {coro [info coroutine] yielding}

	    # cancel all outstanding timers for this coro
	    foreach t $timer {
		catch {
		    after cancel $t	;# cancel old timer
		} e eo
		Debug.HttpdCoro {cancel [info coroutine] $t - $e ($eo)}
	    }

	    # start new timer
	    if {$time > 0} {
		# set new timer
		set timer [after $time [list ::Httpd::$socket TIMEOUT]]	;# set new timer
		Debug.HttpdCoro {timer [info coroutine] $timer}
	    }

	    # unpack event
	    set args [lassign [::yield $retval] op]; set retval ""
	    lappend status $op
	    Debug.HttpdCoro {yield [info coroutine] -> $op}

	    # cancel all outstanding timers for this coro
	    foreach t $timer {
		catch {
		    after cancel $t	;# cancel old timer
		} e eo
		Debug.HttpdCoro {cancel [info coroutine] $t - $e ($eo)}
	    }

	    # dispatch on command
	    switch -- [string toupper $op] {
		TEST {
		    set retval OK
		}

		STATS {
		    set retval {}
		    foreach x [uplevel \#1 {info locals}] {
			catch [list uplevel \#1 [list set $x]] r
			lappend retval $x $r
		    }
		}

		READ {
		    # this can only happen in the reader coro
		    # check the channel
		    if {[chan eof $socket]} {
			Debug.HttpdCoro {[info coroutine] eof detected from yield}
			EOF "closed on reading"
		    } else {
			return $args
		    }
		}

		CLOSING {
		    # we're half-closed
		    # we won't accept any more input but we want to send
		    # all pending responses
		    if {[chan eof $socket]} {
			# remote end closed - just forget it
			EOF "error closed connection"
		    } else {
			# just read incoming data
			chan read $socket
		    }
		}

		SEND {
		    # send a response to client on behalf of consumer
		    set retval [send {*}$args]
		}

		EOF {
		    # we've been informed that the socket closed
		    EOF {*}$args
		}

		DEAD {
		    # we've been informed that the consumer has died
		    EOF {*}$args
		}

		TIMEOUT {
		    # we've timed out - oops
		    after cancel $timer	;# cancel old timer
		    if {[info commands $consumer] eq ""} {
			Debug.HttpdCoro {reader [info coroutine]: consumer error or gone on EOF}
			EOF TIMEOUT
		    } elseif {[catch {
			$consumer [list TIMEOUT [info coroutine]]
		    } e eo]} {
			Debug.HttpdCoro {[info coroutine]: consumer error $e ($eo)}
		    }
		    EOF TIMEOUT
		    set time -1	;# no more timeouts
		}

		default {
		    error "[info coroutine]: Unknown op $op $args"
		}
	    }
	}
    }

    # handle - handle a protocol error
    proc handle {req {reason "Error"}} {
	Debug.error {handle $reason: ([rdump $req])}

	# we have an error, so we're going to try to reply then die.
	corovars transaction generation status closing socket
	lappend status ERROR
	if {[catch {
	    dict set req connection close	;# we want to close this connection
	    if {![dict exists $req -transaction]} {
		dict set req -transaction [incr transaction]
	    }
	    dict set req -generation $generation

	    # send a response to client
	    send $req	;# queue up error response
	} r eo]} {
	    dict append req -error "(handler '$r' ($eo))"
	    Debug.error {'handle' error: '$r' ($eo)}
	}

	# return directly to event handler to process SEND and STATUS
	set closing 1
	chan event $socket readable [list [info coroutine] CLOSING]

	Debug.error {'handle' closing}
	return -level [expr {[info level] - 1}]	;# return to the top coro level
    }

    # coroutine-enabled gets
    proc get {socket {reason ""}} {
	variable maxline
	set result [yield]
	set line ""
	while {[chan gets $socket line] == -1 && ![chan eof $socket]} {
	    set result [yield]
	    if {$maxline && [chan pending input $socket] > $maxline} {
		handle [Http Bad $request "Line too long"] "Line too long"
	    }
	}

	if {[chan eof $socket]} {
	    EOF $reason	;# check the socket for closure
	}

	# return the line
	Debug.HttpdCoro {get: '$line' [chan blocked $socket] [chan eof $socket]}
	return $line
    }

    # coroutine-enabled read
    proc read {socket size} {
	# read a chunk of $size bytes
	set chunk ""
	while {$size && ![chan eof $socket]} {
	    set result [yield]
	    set chunklet [chan read $socket $size]
	    incr size -[string length $chunklet]
	    append chunk $chunklet
	}
	
	if {[chan eof $socket]} {
	    EOF ENTITY	;# check the socket for closure
	}
	
	# return the chunk
	Debug.HttpdCoro {read: '$chunk'}
	return $chunk
    }

    proc parse {lines} {
	# we have a complete header - parse it.
	set r {}
	set last ""
	set size 0
	foreach line $lines {
	    if {[string index $line 0] in {" " "\t"}} {
		# continuation line
		dict append r $last " [string trim $line]"
	    } else {
		set value [join [lassign [split $line ":"] key] ":"]
		set key [string tolower [string trim $key "- \t"]]
		
		if {[dict exists $r $key]} {
		    dict append r $key ",$value"
		} else {
		    dict set r $key [string trim $value]
		}

		# limit size of each field
		variable maxfield
		if {$maxfield
		    && [string length [dict get $r $key]] > $maxfield
		} {
		    handle [Http Bad $request "Illegal header: '$line'"] "Illegal Header"
		}
	    }
	}

	return $r
    }

    variable reader {
	Debug.HttpdCoro {create reader [info coroutine] - $args}

	# unpack all the passed-in args
	set replies {}	;# dict of replies pending
	set requests {}	;# dict of requests unsatisfied
	set satisfied {};# dict of requests satisfied
	set unsatisfied {} ;# dict of requests unsatisfied
	set response 1	;# which is the next response to send?
	set sequence -1	;# which is the next response to queue?
	set writing 0	;# we're not writing yet
	dict with args {}
	set timer {}	;# collection of active timers
	set transaction 0	;# count of incoming requests
	set status INIT	;# record transitions
	set closing 0	;# flag that we want to close

	# keep receiving input requests
	while {1} {
	    # get whole header
	    set headering 1
	    set lines {}
	    while {$headering} {
		set line [get $socket HEADER]
		Debug.HttpdCoro {reader [info coroutine] got line: ($line)}
		if {[string trim $line] eq ""} {
		    # rfc2616 4.1: In the interest of robustness,
		    # servers SHOULD ignore any empty line(s)
		    # received where a Request-Line is expected.
		    if {[llength $lines]} {
			set headering 0
		    }
		} else {
		    lappend lines $line
		}
	    }

	    # parse the header into a request
	    set r [dict merge $prototype [parse [lrange $lines 1 end]]]	;# parse the header
	    dict set r -received [clock microseconds]
	    dict set r -transaction [incr transaction]
	    dict set r -sock $socket

	    # unpack the header line
	    set header [lindex $lines 0]
	    dict set r -method [string toupper [lindex $header 0]]
	    switch -- [dict get $r -method] {
		CONNECT {
		    # stop the bastard SMTP spammers
		    Block block [dict get $r -ipaddr] "CONNECT method"
		    handle [Http NotImplemented $r "Connect Method"] "CONNECT method"
		}

		GET - PUT - POST - HEAD {}

		default {
		    # Could check for and service FTP requestuests, etc, here...
		    dict set r -error_line $line
		    handle [Http Bad $r "Method unsupported '[lindex $header 0]'" 405] "Method Unsupported"
		}
	    }

	    dict set r -version [lindex $header end]
	    dict set r -uri [join [lrange $header 1 end-1]]

	    # check URI length (per rfc2616 3.2.1
	    # A server SHOULD return 414 (Requestuest-URI Too Long) status
	    # if a URI is longer than the server can handle (see section 10.4.15).)
	    variable maxurilen
	    if {$maxurilen && [string length [dict get $r -uri]] > $maxurilen} {
		# send a 414 back
		handle [Http Bad $r "URI too long '[dict get $r -uri]'" 414] "URI too long"
	    }

	    if {[string match HTTP/* [dict get $r -version]]} {
		dict set r -version [lindex [split [dict get $r -version] /] 1]
	    }

	    # Send 505 for protocol != HTTP/1.0 or HTTP/1.1
	    if {([dict get $r -version] != 1.1)
		&& ([dict get $r -version] != 1.0)} {
		handle [Http Bad $r "HTTP Version '[dict get $r -version]' not supported" 505] "Unsupported HTTP Version"
	    }

	    Debug.HttpdCoro {reader got request: ($r)}

	    # parse the URL
	    set r [dict merge $r [Url parse [dict get $r -uri]]]

	    # block spiders by UA
	    if {[info exists ::spiders([Dict get? $r user-agent])]} {
		Block block [dict get $r -ipaddr] "spider UA ([Dict get? $r user-agent])"
		handle [Http NotImplemented $r "Spider Service"] "Spider"
	    }

	    # analyse the user agent strings.
	    dict set r -ua [ua [Dict get? $r user-agent]]

	    # check the incoming ip for blockage
	    if {[Block blocked? [Dict get? $r -ipaddr]]} {
		handle [Http Forbidden $r] Forbidden
	    } elseif {[Honeypot guard r]} {
		# check the incoming ip for bot detection
		# this is a bot - reply directly to it
		send $r		;# queue up error response
		continue
	    }

	    # ensure that the client sent a Host: if protocol requires it
	    if {[dict exists $r host]} {
		# client sent Host: field
		if {[string match http:* [dict get $r -uri]]} {
		    # rfc 5.2 1 - a host header field must be ignored
		    # if request-line specified an absolute URL host/port
		    set r [dict merge $r [Url parse [dict get $r -uri]]]
		    dict set r host [Url host $r]
		} else {
		    # no absolute URL was specified by the request-line
		    # use the Host field to determine the host
		    foreach c [split [dict get $r host] :] f {host port} {
			dict set r -$f $c
		    }
		    dict set r host [Url host $r]
		    set r [dict merge $r [Url parse http://[dict get $r host][dict get $r -uri]]]
		}
	    } elseif {[dict get $r -version] > 1.0} {
		handle [Http Bad $r "HTTP 1.1 required to send Host"] "No Host"
	    } else {
		# HTTP 1.0 isn't required to send a Host request but we still need it
		if {![dict exists $r -host]} {
		    # make sure the request has some idea of our host&port
		    dict set r -host $host
		    dict set r -port $port
		    dict set r host [Url host $r]
		}
		set r [dict merge $r [Url parse http://[Url host $r]/[dict get $r -uri]]]
	    }
	    dict set r -url [Url url $r]	;# normalize URL

	    # rfc2616 14.10:
	    # A system receiving an HTTP/1.0 (or lower-version) message that
	    # includes a Connection header MUST, for each connection-token in this
	    # field, remove and ignore any header field(s) from the message with
	    # the same name as the connection-token.
	    if {[dict get $r -version] < 1.1 && [dict exists $r connection]} {
		foreach token [split [dict get $r connection] ","] {
		    catch {dict unset r [string trim $token]}
		}
		dict unset r connection
	    }

	    # completed request header decode - now dispatch on the URL
	    Debug.HttpdCoro {reader complete: $header ([rdump $r])}

	    # rename fields whose names are the same in request/response
	    foreach n {cache-control} {
		if {[dict exists $r $n]} {
		    dict set r -$n [dict get $r $n]
		    dict unset r $n
		}
	    }

	    # rfc2616 4.3
	    # The presence of a message-body in a request is signaled by the
	    # inclusion of a Content-Length or Transfer-Encoding header field in
	    # the request's headers.
	    if {[dict exists $r transfer-encoding]} {
		set te [dict get $r transfer-encoding]
		# chunked 3.6.1, identity 3.6.2, gzip 3.5, compress 3.5, deflate 3.5
		set tels {}
		array set params {}

		variable te_encodings
		variable te_params
		foreach tel [split $te ,] {
		    set param [lassign [split $tel ";"] tel]
		    set tel [string trim $tel]
		    if {$tel ni $te_encodings} {
			# can't handle a transfer encoded entity
			handle [Http NotImplemented $r "$tel transfer encoding"] "Unimplemented TE"
			continue
			# see 3.6 - 14.41 for transfer-encoding
			# 4.4.2 If a message is received with both
			# a Transfer-EncodIing header field
			# and a Content-Length header field,
			# the latter MUST be ignored.
		    } else {
			lappend tels $tel
			set params($tel) [split $param ";"]
		    }
		}

		dict set r -te $tels
		dict set r -te_params [array get params]
	    } elseif {[dict get $r -method] in {POST PUT}
		      && ![dict exists $r content-length]} {
		dict set r -te {}
		
		# this is a content-length driven entity transfer
		# 411 Length Required
		handle [Http Bad $r "Length Required" 411] "Length Required"
	    }

	    if {[dict get $r -version] >= 1.1
		&& [dict exists $r expect]
		&& [string match *100-continue* [string tolower [dict get $r expect]]]
	    } {
		# the client wants us to tell it to continue
		# before reading the body.
		# Do so, then proceed to read
		puts -nonewline $socket "HTTP/1.1 100 Continue\r\n"
	    }

	    # fetch the entity (if any)
	    if {"chunked" in [Dict get? $r -te]} {
		set chunksize 1
		while {$chunksize} {
		    chan configure $socket -translation {crlf binary}
		    set chunksize 0x[get $socket CHUNK]
		    chan configure $socket -translation {binary binary}
		    if {$chunksize eq "0x"} {
			Debug.HttpdCoro {Chunks all done}
			break	;# collected all the chunks
		    }
		    set chunk [read $socket $chunksize]
		    Debug.HttpdCoro {Chunk: $chunksize ($chunk)}
		    get $socket CHUNK
		    dict append r -entity $chunk

		    # enforce server limits on Entity length
		    variable maxentity
		    if {$maxentity > 0
			&& [string length [dict get $r -entity]] > $maxentity} {
			# 413 "Request Entity Too Large"
			handle [Http Bad $r "Request Entity Too Large" 413] "Entity Too Large"
		    }
		}
	    } elseif {[dict exists $r content-length]} {
		set left [dict get $r content-length]

		# enforce server limits on Entity length
		variable maxentity
		if {$maxentity > 0 && $left > $maxentity} {
		    # 413 "Request Entity Too Large"
		    handle [Http Bad $r "Request Entity Too Large" 413] "Entity Too Large"
		}

		if {$left == 0} {
		    dict set r -entity ""
		    # the entity, length 0, is therefore already read
		    # 14.13: Any Content-Length greater than
		    # or equal to zero is a valid value.
		} else {
		    set entity ""
		    chan configure $socket -translation {binary binary}
		    Debug.HttpdCoro {reader getting entity of length ($left)}
		    while {$left > 0} {
			set chunk [read $socket $left]
			incr left -[string length $chunk]
			Debug.HttpdCoro {reader getting remainder of entity of length ($left)}
			dict append r -entity $chunk
			Debug.HttpdCoro {reader got whole entity}
		    }
		}
	    }

	    # reset socket to header config, having read the entity
	    chan configure $socket -encoding binary -translation {crlf binary}

	    # now we postprocess/decode the entity
	    Debug.entity {entity read complete - '[Dict get? $r -te]'}
	    if {"gzip" in [Dict get? $r -te]} {
		dict set r -entity [zlib deflate [dict get $r -entity]]
	    }

	    # remove 'netscape extension' length= from if-modified-since
	    if {[dict exists $r if-modified-since]} {
		dict set r if-modified-since [lindex [split [dict get $r if-modified-since] {;}] 0]
	    }

	    # trust x-forwarded-for if we get a forwarded request from a local ip
	    # (presumably local ip forwarders are trustworthy)
	    set forwards {}
	    if {[dict exists $r x-forwarded-for]} {
		foreach xff [split [Dict get? $r x-forwarded-for] ,] {
		    set xff [string trim $xff]
		    set xff [lindex [split $xff :] 0]
		    if {$xff eq ""
			|| $xff eq "unknown"
			|| [Http nonRouting? $xff]
		    } continue
		    lappend forwards $xff
		}
	    }
	    lappend forwards [dict get $r -ipaddr]
	    dict set r -forwards $forwards
	    dict set r -ipaddr [lindex $forwards 0]
	    
	    # check Cache for match
	    if {[dict size [set cached [Cache check $r]]] > 0} {
		# reply from cache
		dict set cached -transaction [dict get $r -transaction]
		dict set cached -generation [dict get $r -generation]
		dict set unsatisfied [dict get $cached -transaction] {}

		Debug.HttpdCoro {sending cached ([rdump $cached])}
		send $cached 0	;# send cached response directly
		continue
	    }

	    # deliver request to consumer
	    if {[info commands $consumer] ne {}} {
		# deliver the assembled request to the consumer
		dict set unsatisfied [dict get $r -transaction] {}
		after 1 [list $consumer [list INCOMING $r]]
		Debug.HttpdCoro {reader [info coroutine]: sent to consumer, waiting for next}
	    } else {
		# the consumer has gone away
		Debug.HttpdCoro {reader [info coroutine]: consumer gone $consumer}
		lappend status DOA
		set closing 1
		chan event $socket readable [list [info coroutine] CLOSING]
	    }
	}
    }

    proc disconnect {args} {}
    proc disassociate {args} {}

    # the request consumer
    variable consumer {
	Debug.HttpdCoro {consumer: $args}
	dict with args {}
	set retval ""
	while {1} {
	    set args [lassign [::yield $retval] op]
	    Debug.HttpdCoro {consumer [info coroutine] got: $op $args}
	    switch -- $op {
		TIMEOUT -
		DEAD -
		EOF {
		    return	;# kill self by returning
		}

		TEST {
		    set retval OK
		}

		STATS {
		    set retval {}
		    foreach x [uplevel \#1 {info locals}] {
			catch [list uplevel \#1 [list set $x]] r
			lappend retval $x $r
		    }
		}

		INCOMING {
		    set r [lindex $args 0]		;# get the request
		    set r [Cookies 4Server $r]		;# process cookies
		    catch {Responder do $r} rsp eo	;# process the request

		    # handle response code
		    switch [dict get $eo -code] {
			0 -
			2 { # ok - return
			    if {![dict exists $rsp -code]} {
				set rsp [Http Ok $rsp]
			    }
			}

			1 { # error
			    set rsp [Http ServerError $r $rsp $eo]
			}
		    }

		    # post-process the response
		    if {[catch {
			Responder post $rsp
		    } e eo]} {
			Debug.error {POST ERROR: $e ($eo)} 1
			set rsp [Http ServerError $r $e $eo]
		    } else {
			Debug.HttpdCoro {POST: [rdump $e]} 10
			set rsp $e
		    }

		    # ask socket coro to send the response for us
		    if {[catch {
			$reader [list SEND $rsp]
		    } e eo]} {
			Debug.error {[info coroutine] sending terminated via $reader: $e ($eo)} 1
			return
		    } elseif {$e in {EOF ERROR}} {
			Debug.HttpdCoro {[info coroutine] sending terminated via $reader: $e} 1
			return
		    }
		}
	    }
	}
    }

    # we have received a new connection
    # set up a consumer and a reader for it
    proc associate {request} {
	set socket [dict get $request -sock]
	set cid [dict get $request -cid]	;# remember the connection id
	Debug.socket {associate $request $socket}

	# condition the socket
	chan configure $socket -buffering none -translation {crlf binary}

	# generate a connection record prototype
	variable generation	;# unique generation
	set gen [incr generation]
	set request [dict merge $request [list -sock $socket -generation $gen]]

	# create reader coroutine
	variable reader
	set R ::Httpd::${socket}
	if {[info commands $R] ne {}} {
	    # the old socket stuff hasn't yet been cleaned up.
	    # this is potentially very bad.
	}

	# construct consumer
	#set cr ::Httpd::CO_[uniq]
	set cr ::Httpd::CO_${socket}
	if {[info commands $cr] ne ""} {
	    # the consumer seems to be lingering - we have to tell it to die
	    set cn ::Httpd::CO_DEAD_[uniq]
	    rename $cr $cn	;# move it out of the way first
	    Debug.log {consumer $cr not dead yet, rename to $cn to kill it.}
	    after 1 [list $cn [list EOF "socket's gone"]]	;# ensure the old consumer's dead
	}
	variable consumer; coroutine $cr ::apply [list args $consumer ::Httpd] reader $R

	# construct the reader
	variable rxtimeout
	set result [coroutine $R ::apply [list args $reader ::Httpd] socket $socket timeout $rxtimeout consumer $cr prototype $request generation $gen cid $cid]

	# ensure there's a cleaner for this connection's coros
	trace add command $cr delete [list $R DEAD $cr]
	trace add command $R delete [list $cr DEAD $R]

	# start the ball rolling
	chan event $socket readable [list $R READ]

	return $result
    }

    proc corotest {} {
	set result {}
	foreach coro [info commands ::Httpd::sock*] {
	    lappend result $coro [$coro TEST]
	}
	foreach coro [info commands ::Httpd::CO_*] {
	    lappend result $coro [$coro TEST]
	}
	return $result
    }

    proc stats {} {
	set result {}
	foreach coro [info commands ::Httpd::sock*] {
	    lappend result $coro [$coro STATS]
	}
	foreach coro [info commands ::Httpd::CO_*] {
	    lappend result $coro [$coro STATS]
	}
	return $result
    }

    proc chans {} {
	foreach cchan [info commands ::Httpd::sock*] {
	    set chan [namespace tail $cchan]
	    catch {
		list eof [chan eof $chan] input [chan pending input $chan] output [chan pending output $chan] blocked [chan blocked $chan] readable [chan event $chan readable] writable [chan event $chan writable] {*}[chan configure $chan]
	    } el
	    lappend result "name $chan $el"
	}
	return $result
    }

    namespace export -clear *
    namespace ensemble create -subcommands {}
}

# load up per-worker locals.
catch {source [file join [file dirname [info script]] wlocal.tcl]}

Debug on log 10
Debug off close 10
Debug off socket 10
Debug off http 10
Debug off entity 10
# now we're able to process commands
