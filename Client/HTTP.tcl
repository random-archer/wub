# HTTP 1.1 client

set MODULE(HTTP) {
    {
	HTTP constructs a connection to a host and initiates a series of HTTP 1.1 requests, it supports HTTP methods [[get]] [[put]] [[post]] [[delete]], and a [[close]] method for terminating the connection.

	Server responses are sent to the consumer in the form: [[list RESPONSE response]] where response is a response dictionary containing the originally requested url in X-url, and object sending the response in X-object, and an X-type of RESPONSE.  The actual response content may be found as [[dict get $response -content]].

	If the configuration variable ''justcontent'' is true, then server responses to the consumer consist of only the received entity, that is the content, of the response.  So a consumer will get the HTML of a page, for example.  This is ok if you know your request isn't going to fail.

	== Opening an HTTP Connection ==
	[[HTTP new $url $consumer ...]] is the general form of connection construction.  An HTTP connection ''must'' be constructed with at least a URL (to get) and a Consumer (to send responses to.)  As soon as the HTTP object comes into being, it sends all the requests its constructor has been given.

	Additional arguments to the constructor may be of the form:

	;get/put/post/delete {$url ...}: which queues up a protocol request in the pipeline, to be sent to the host in order.  Additional arguments are treated as HTTP protocol elements, and added to the request dict as it's sent.  Careful now.
	;var value: configuration variables (see Configuration, below)

	== Sending Requests on an HTTP Connection ==

	Requests may be sent in the form: [[$object ''op'' $url]] where ''op'' is one of [[get]], [[put]]. [[post]], [[delete]].  The url must have the same host and port as the HTTP connection was created with, and in fact can be shortened to omit the leading 'http://' and host information.

	=== Request Queries ===
	Queries are simply formed into the requested url.  [Wub]'s [Query] and [Url] packages may be of use in this, to construct properly formatted URLs and URL queries.

	=== Request Entities ===
	Entities, if any, can be sent as follows: [[$object post $url $entity]].  If you wish to indicate other information about the entity, it can be included thus: [[$object post $url $entity content-type text/html]] for example.

	The request will be formatted and sent to the host server, and its response indicated to the consumer.
	
	== HTTP Connection Termination ==
	If the configuration variable ''notify'' is true, then termination of the connection calls that script with a response dict containing the X-type CLOSED indication and an X-reason containing the reason for closure, otherwise the consumer receives that dict.   A consumer managing multiple connections may use the X-object element to associate responses with connections.

	The [[close]] method requests that the object destroy itself and close the connection after all outstanding responses are collected and have been forwarded as responses.

	An eof on the socket destroys the object immediately after sending a CLOSED indication to the consumer.  By the time the consumer receives the CLOSED indication, the HTTP object has probably already been destroyed.

	[[$object destroy]] will also immediately close HTTP connections.

	== Examples ==
	[[HTTP new $consumer get http://somewhere.com/something get http://somewhere.com/somethingelse ...]]
	[[http://somewhere.com $consumer get http://somewhere.com/somethingelse]] -- equivalent

	== Limitations ==

	=== Protocol Incompatibilities ===
	TBD: The HTTP1.1 protocol requires that a pipeline (of queued requests) be stalled until the response to a PUT or POST request has been received.  This version of HTTP doesn't do that, but later versions will.

	=== Redirections ===
	Servers may respond with redirection response codes, indicating that the requested resource is located elsewhere.  This may necessitate a new connection be opened, perhaps to a different host.  The HTTP package doesn't attempt to follow redirections, reasoning that the consumer is in a better position to know what it wants to do with them.

	=== Cookies ===
	Cookies are received, and may be parsed with the [Wub] [Cookies] module, but are not further processed by HTTP.

	=== Caching ===
	No attempt is made to cache or to understand caching instructions.

	== ToDo ==
	Track [[rename]]s of the object command - this will impact on [[fileevent]] ... it's not safe to rename the object.
    }
    {consumer "A script prefix to consume responses from the connection"}
    {notify "Script called with notification of completion (default: none)"}
    {justcontent "boolean: the consumer just wants the content (default: no)"}
}

package require Tcl 8.6	;# minimum version of tcl required
package require TclOO

# use the new coro functionality
# temporary compatibility shim for coroutines
# handle new coro interface
if {[llength [info command ::yieldm]]} {
} elseif {[llength [info command ::tcl::unsupported::yieldm]]} {
    namespace eval tcl::unsupported namespace export yieldm
    namespace import tcl::unsupported::yieldm
    interp alias {} ::Coroutine {} ::coroutine
} elseif {[llength [info command ::yieldto]]} {
    # this is the new 8.6b3 yield system - yield takes arbitrary args
    interp alias {} ::Coroutine {} ::coroutine
    #interp alias {} ::yieldm {} ::yieldto return -level 0
    proc ::yieldm {args} { yieldto return -level 0 {*}$args }
}

# import the relevant commands from Wub Http package
if {[catch {package require Http}]} {
    namespace eval ::Http {}
    # return an HTTP date
    proc ::Http::Date {{seconds ""}} {
	if {$seconds eq ""} {
	    set seconds [clock seconds]
	}

	return [clock format $seconds -format {%a, %d %b %Y %T GMT} -gmt true]
    }
}

# import the relevant commands from Wub Url package
if {[catch {package require Url}]} {
    namespace eval ::Url {
	# subset the Url package for stand-alone use
	proc url {args} {
	    if {[llength $args] == 1} {
		set args [lindex $args 0]
	    }
	    # minimize -port
	    if {[dict exists $args -port]
		&& ([dict get $args -port] eq "" || [dict get $args -port] eq "80")} {
		dict unset args -port
	    }
	    
	    foreach {part pre post} {
		-scheme "" :
		-host // ""
		-port : ""
		-path "" ""
	    } {
		if {[dict exists $args $part]} {
		    append result "${pre}[dict get $args $part]${post}"
		}
	    }
	    return $result
	}
	proc uri {x args} {
	    set result [url $x]

	    foreach {part pre post} {
		-query ? ""
		-fragment \# ""
	    } {
		if {[dict exists $x $part]} {
		    append result "${pre}[dict get $x $part]${post}"
		}
	    }
	    return $result
	}
	proc normalize {url} {
	    while {[set new [regsub -all {(/+)|(^[.][.]/)|(^/[.][.])|(/[^/]+/[.][.]$)|(/[^/]+/[.][.]/)|(^[.]/)|(/[.]$)|(/[.]/)|(^[.][.]$)|(^[.]$)} $url /]] ne $url} {
		set url $new
	    }
	    return "/[string trimleft $url /]"
	}
	proc parse {url {normalize 1}} {
	    array set x {}
	    regexp {^(([^:/?\#]+):)?(//([^/?\#]*))?([^?\#]*)([?]([^\#]*))?(\#(.*))?$} $url \
		-> . x(-scheme) . x(-authority) x(-path) . x(-query) . x(-fragment)
	    regexp {^(([^@]+)@)?([^@:]+)?(:([0-9]+))?$} $x(-authority) \
		-> . x(-authority) x(-host) . x(-port)

	    if {$normalize} {
		set x(-path) [normalize $x(-path)]	;# fix up oddities in URLs
	    }
	    
	    foreach n [array names x] {
		if {$x($n) eq ""} {
		    unset x($n)
		}
	    }
	    if {[info exists x(-scheme)]} {
		set x(-url) [url [array get x]]
	    }
	    return [array get x]
	}
	
	# construct the host part of a URL dict
	proc host {x} {
	    if {[dict exists $x -port]
		&& [dict get $x -port] ne {}
		&& [dict get $x -port] != 80} {
		return "[dict get $x -host]:[dict get $x -port]"
	    } else {
		return "[dict get $x -host]"
	    }
	}

	proc http {x args} {
	    set result ""
	    foreach {part pre post} {
		-path "" ""
		-fragment \# ""
		-query ? ""
	    } {
		if {[dict exists $x $part]} {
		    append result "${pre}[dict get $x $part]${post}"
		}
	    }
	    return $result
	}
	
	namespace export -clear *
	namespace ensemble create -subcommands {}
    }
}

if {[catch {package require Debug}]} {
    proc Debug.HTTP {args} {}
    proc Debug.HTTP {args} {puts stderr HTTP@[uplevel subst $args]}
    proc Debug.HTTPdetail {args} {}
    #proc Debug.HTTPdetail {args} {puts stderr HTTPdetail@[uplevel subst $args]}
} else {
    Debug define HTTP 10
    Debug define HTTPdetail 10
}

# this enables urls to be commands.
if {[catch {package require know}]} {
    proc know {cond body} {
	if {![info complete $body]} {error "incomplete command(s) $body"}
	proc ::unknown {args} [string map [list @c@ $cond @b@ $body] {
	    if {![catch {expr {@c@}} res eo] && $res} {
		return [eval {@b@}]
	    }
	}][info body ::unknown]
    } ;# RS
}

# this parses the URL into a host part and a 'get $path' part.
know {[string match http://* [lindex $args 0]]} {
    # parse the URL
    set urld [Url parse [lindex $args 0]]
    Debug.HTTPdetail {parsed URL: $urld}
    set host [Url host $urld]
    set path [Url http $urld]
    if {[dict exists $urld -fragment]} {
	dict unset urld -fragment	;# we don't pass fragments
    }
    if {$path ne ""} {
	set path [list get $path]	;# make a 'get' op for path remainder
    }

    HTTP run [Url uri $urld] [lindex $args 1] $path	;# close close
}

know {[string match https://* [lindex $args 0]]} {
    # parse the URL
    set urld [Url parse [lindex $args 0]]
    Debug.HTTPdetail {parsed URL: $urld}
    set host [Url host $urld]
    set path [Url http $urld]
    if {[dict exists $urld -fragment]} {
	dict unset urld -fragment	;# we don't pass fragments
    }
    if {$path ne ""} {
	set path [list get $path]	;# make a 'get' op for path remainder
    }

    HTTP run [Url uri $urld] [lindex $args 1] $path
}

package provide HTTP 2.0


namespace eval ::HTTPClient {}

oo::class create HTTP {
    # send - send an op HTTP request to the server
    method send {method url args} {
	variable socket
	variable sent
	variable host
	variable port
	variable http
	Debug.HTTP {[self] send method:$method url:$url ($args)}
	if {[llength $args]%2} {
	    set entity [lindex $args 0]
	    set args [lrange $args 1 end]
	    Debug.HTTP {[self] sending entity length [string length $entity]}
	}

	set T [dict merge $http $args [list -scheme http -port $port -host $host] [Url parse $url]]
	set T [dict merge $T [list -method $method date [::Http::Date] host $host]]
	variable txcount; variable requrl; set requrl([incr txcount]) [Url uri $T]
	Debug.HTTP {[self] T: ($T) #$txcount -> [Url http $T] -> [Url uri $T]}

	# format entity
	if {[info exists entity]} {
	    # encode entity body
	    dict set T content-length [string length $entity]
	}

	# format up header
	set request "[string toupper $method] [Url http $T] HTTP/1.1\r\n"

	dict for {n v} [dict filter $T key {[a-zA-Z]*}] {
	    if {[string length $v] > 100} {
		# break long lines into partial lines
		set sv {}
		while {[string length $v] > 100} {
		    lappend sv [string range $v 0 99]
		    set v [string range $v 100 end]
		}
		lappend sv $v
		set v [join $sv "\r\n "]
	    }
	    append request "$n: $v\r\n"
	}
	append request "\r\n"	;# signal end of header
	chan puts -nonewline $socket $request
	Debug.HTTPdetail {[self] Sent header: [string map {\r \\r \n \\n} $request]}

	if {[info exists entity]} {
	    # send the entity
	    chan puts -nonewline $socket $entity
	}

	variable outstanding; incr outstanding
	variable reader
	chan event $socket readable [list $reader READ]

	Debug.HTTP {[self] sent $method $url - $outstanding outstanding}
    }

    method reason {} {
	variable reason; return $reason
    }

    method gets {} {
	variable socket

	set line ""
	set gone [catch {chan eof $socket} eof]
	while {!$gone && !$eof
	       && [chan gets $socket line] != -1
	       && [chan blocked $socket]
	   } {
	    ::yieldm
	    set gone [catch {chan eof $socket} eof]
	}

	if {$gone || $eof} {
	    variable reason "EOF reading HEADER"
	    Debug.HTTPdetail {[self] gets: EOF reading HEADER}
	    [self] destroy
	} else {
	    Debug.HTTPdetail {[self] gets: '$line' [chan blocked $socket] [chan eof $socket]}
	    return $line
	}
    }

    method read {{size -1}} {
	variable socket
	Debug.HTTP {[self] Reading $size}

	set chunk ""
	set gone [catch {chan eof $socket} eof]
	while {$size && !$gone && !$eof} {
	    ::yieldm	;# wait for read event
	    set chunklet [chan read $socket {*}[expr {$size>0?$size:""}]]	;# get some
	    append chunk $chunklet			;# remember it
	    incr size -[string length $chunklet]	;# how much left?
	    set gone [catch {chan eof $socket} eof]
	    Debug.HTTPdetail {[self] Read chunk ($size left)}
	}

	if {$gone || $eof} {
	    variable reason "EOF reading ENTITY"
	    return $chunk	;# can just EOF in entity
	} else {
	    # we have successfully read our chunk of $size
	    Debug.HTTPdetail {[self] Read: chunk of size $size}
	    return $chunk
	}
    }

    # parse lines into response dict
    method parse {lines} {
	set r {}
	set lines [lassign $lines header]
	Debug.HTTP {[self] reader header: $header ($r)}

	# split out some interesting parts of the first header line
	dict set r -message [join [lassign [split $header] version code]]
	dict set r -version $version
	dict set r -code $code

	set key ""
	foreach line $lines {
	    if {[string index $line 0] in {" " "\t"}} {
		# continuation line
		dict append r $key " [string trim $line]"
	    } else {
		set value [join [lassign [split $line ":"] key] ":"]
		set key [string tolower [string trim $key "- \t"]]
		
		if {[dict exists $r $key]} {
		    dict append r $key ",$value"
		} else {
		    dict set r $key [string trim $value]
		}
	    }
	}
	return $r
    }

    # reader proc - the functional base of the read coroutine
    method reader {} {
	# unpack all the passed-in args
	::yieldm

	# keep receiving input resulting from our requests
	variable socket
	set gone [catch {chan eof $socket} eof]
	while {!$gone && !$eof} {
	    # get whole header
	    # keep a count of the number of packets received
	    variable rqcount; incr rqcount

	    variable requrl
	    set r [list X-type RESPONSE X-object [self] X-count $rqcount X-url $requrl($rqcount)]

	    set headering 1; set bogus 0
	    set lines {}
	    while {$headering} {
		set line [my gets]
		Debug.HTTP {[self] reader got line: ($line)}
		if {[string trim $line] eq ""} {
		    if {[llength $lines]} {
			set headering 0
		    }
		} elseif {[string match <* [string trim $line]]} {
		    set headering 0
		    set bogus 1
		} else {
		    lappend lines $line
		}
	    }

	    if {$bogus} {
		# some sites (yes, ReCAPTCHA, you) don't even send headers
		Debug.HTTP {[self] This site is bogus, no header sent, just content}
		set entity $line
		while {![eof $socket]} {
		    append entity \n [my gets]
		}
		dict set r -content $entity
	    } else {
		# got the header
		set r [dict merge $r [my parse $lines]]	;# parse the header
		
		# now we have to fetch the entity (if any)
		if {[dict exists $r content-length]} {
		    set left [dict get $r content-length]
		    set entity ""
		    chan configure $socket -encoding binary -translation {binary binary}
		    Debug.HTTP {[self] reader getting entity of length ($left)}
		    while {$left > 0} {
			set chunk [my read $left]
			incr left -[string length $chunk]
			Debug.HTTP {[self] reader getting remainder of entity of length ($left)}
			dict append r -content $chunk
		    }
		    Debug.HTTP {[self] reader got whole entity}
		} elseif {[dict exists $r transfer-encoding]} {
		    switch -- [dict get $r transfer-encoding] {
			chunked {
			    set chunksize 1
			    while {$chunksize} {
				chan configure $socket -encoding [encoding system] -translation {crlf binary}
				set chunksize 0x[my gets]
				chan configure $socket -encoding binary -translation {binary binary}
				Debug.HTTPdetail {chunksize: $chunksize}
				if {$chunksize eq "0x"} {
				    set chunksize 0
				}
				if {!$chunksize} {
				    my gets
				    Debug.HTTP {[self] Chunks all done}
				    break
				}
				set chunk [my read $chunksize]
				my gets	;# get the closing \n
				Debug.HTTP {[self] Chunk: $chunksize}
				dict append r -content $chunk
			    }
			}
			default {
			    error "Unknown transfer encoding"
			}
		    }
		} else {
		    chan configure $socket -encoding binary -translation {binary binary}
		    dict set r -content [my read]	;# read to EOF
 		}
	    }

	    # reset to header config
	    if {![chan eof $socket]} {
		chan configure $socket -encoding [encoding system] -translation {crlf binary}
	    }

	    # check content-encoding and gunzip content if necessary
	    if {[dict exists $r content-encoding]} {
		switch -- [string tolower [dict get $r content-encoding]] {
		    gzip {
			set content [dict get $r -content]
			dict set r -content [::zlib gunzip $content]
		    }
		    default {}
		}
	    }

	    # hand consumer the result
	    variable consumer
	    variable justcontent
	    if {$justcontent} {
		after 1 [list {*}$consumer [list [dict get $r -content]]]
	    } else {
		Debug.HTTPdetail {[self] formatting up consumer message $rqcount}
		after 1 [list {*}$consumer $r]
	    }

	    # count the outstanding responses left
	    # close if there are none
	    variable outstanding; incr outstanding -1
	    Debug.HTTP {[self] outstanding: $outstanding}

	    variable closing
	    if {[dict exists $r connection]
		&& [string tolower [dict get $r connection]] eq "close"
	    } {
		set outstanding 0
		incr closing
	    }

	    if {$closing && !$outstanding} {
		variable reason "requested by WRITER"
		my destroy
	    } elseif {!$outstanding} {
		# nothing to read
		variable reader
		chan event $socket readable [list $reader EOF]
	    }

	    Debug.HTTP {[self] reader: sent response, waiting for next}
	    if {[::yieldm] eq "EOF"} break
	    set gone [catch {chan eof $socket} eof]
	}

	my destroy	;# reader's gone, that's all she wrote
    }

    # writer - the functional basis of the writer coroutine
    method writer {args} {
	# writer - coro to send HTTP requests to a server

	variable txcount
	# construct a request template
	variable template
	variable http [dict merge $template $args] ;# complete request template
	dict set http User-Agent "TclHTTP/[package present HTTP]"
	variable closing 0

	# send all ops we have queued
	variable ops
	variable reason
	if {[info exists ops]} {
	    Debug.HTTP {[self] initial ops: $ops}
	    foreach {op val} $ops {
		if {$op eq "close"} {
		    # we've been asked to close
		    Debug.HTTP {[self] closing upon request}
		    set reason "Requested by Consumer"
		    set closing 1
		} else {
		    my send $op {*}$val	;# send init ops
		}
	    }
	}
	
	# we've closed per request - error on any more requests
	if {$closing} {
	    ::yieldm $closing; error "writer is closed: '$reason'"
	}

	# after initial ops are sent, sit in loop awaiting new op requests
	# get next event
	set args [lassign [::yieldm $closing] op url]
	set op [string tolower $op]
	while {!$closing} {
	    Debug.HTTP {[self] writer op:$op url:$url args:$args}
	    switch -- $op {
		close {
		    set reason "Requested by Consumer"
		    break	;# terminate peacefully per request
		}
		get - put - post - head - delete {
		    # got a protocol operator from consumer
		    my send $op $url {*}$args
		}
		default {
		    error "Unknown op: $op $url $args"
		}
	    }

	    # get next event
	    set args [lassign [::yieldm $closing] op url]
	    set op [string tolower $op]
	}

	Debug.HTTP {[self] writer closed: '$reason'}
	return 1	;# terminate writer peacefully
    }

    # forward some methods for writing
    method write {op url args} {
	variable closing; variable reason
	if {$closing} {
	    error "HTTP [self] has closed: '$reason'"
	}
	variable writer; $writer $op $url {*}$args
    }

    # start reader coroutine
    method start_reader {} {
	# create coros inside our ns
	variable socket
	set ns [info object namespace [self]]

	# create reader coroutine
	variable reader ${ns}::${socket}R
	coroutine $reader [self] reader
	trace add command $reader delete [list [self] destroy]
    }

    # start writer coroutine
    method start_writer {} {
	# create coros inside our ns
	variable socket
	set ns [info object namespace [self]]

	variable writer ${ns}::${socket}W 
	set result [coroutine $writer [self] writer]

	if {!$result} {
	    # writer reports that it's open and ready to go
	    # its lifetime is [self]'s lifetime
	    trace add command $writer delete [list [self] destroy]
	}

	return $result
    }

    destructor {
	variable socket; variable reason; variable urld
	if {![info exists socket]} {
	    set socket "NO SOCKET"
	}
	Debug.HTTP {[self]: $socket ($urld) closed because: '$reason'}

	# notify consumer that we've closed
	variable rqcount
	set close [list X-type CLOSED X-count [incr rqcount] X-reason $reason]

	variable notify
	if {$notify ne ""} {
	    # consumer wants special close notification
	    catch {
		after 1 {*}$notify $close	;# notify completion
	    }
	} else {
	    # consumer wants close in normal event stream
	    variable consumer
	    catch {
		after 1 {*}$consumer $close	;# send close event
	    }
	}

	# close the socket
	variable socket
	catch {chan close $socket}

	# destroy coroutines
	variable reader; catch {rename $reader {}}
	variable writer; catch {rename $writer {}}
    }

    constructor {url _consumer args} {
	Debug.HTTP {[self] construct $url $_consumer $args}
	variable closing 0		;# signals EOF to both reader and writer
	variable outstanding 0	;# counts outstanding packets
	variable rqcount -1		;# counts received responses
	variable txcount -1		;# counts sent requests
	variable reason "server closed connection"	;# reason for closure
	variable consumer $_consumer	;# who's consuming this?
	variable template {accept */* accept-encoding gzip}	;# http template
	variable notify ";#"		;# notify close to consumer?
	variable justcontent 0		;# consumer only wants content
	variable sockopts {}		;# default socket options

	if {[llength $args] == 1} {
	    set args [lindex $args 0]
	}
 
	# differentiate variable decls and HTTP operations
	variable ops {}
	foreach {n v} $args {
	    if {$n in {get put post delete head close}} {
		lappend ops $n $v	;# queue ops up for writer
	    } else {
		variable $n $v
	    }
	}

	# parse url into host,port
	variable urld [Url parse $url]
	Debug.HTTPdetail {[self] url dict: $urld ops: ($ops)}
	if {![dict exist $urld -host]} {
	    error "'$url' is not a properly formed URL"
	}
	variable host [dict get $urld -host]
	if {[dict exists $urld -port]} {
	    variable port [dict get $urld -port]
	} else {
	    if {[dict get $urld -scheme] ne "https"} {
		variable port 80
	    } else {
		variable port 443
	    }
	}

	# forward some convenience methods
	foreach v {get put post head delete close} {
	    oo::objdefine [self] forward $v [self] write $v	;# forward the method to the coro
	}
    }

    # connect HTTP socket to host
    method connect {} {
	variable urld
	variable socket ""
	variable sockopts; variable host; variable port
	set state init
	if {[catch {
	    if {[dict get $urld -scheme] ne "https"} {
		Debug.HTTPdetail {[self] connect: $host $port}
		set state connect
		socket -async {*}$sockopts $host $port	;# create the socket
	    } else {
		Debug.HTTPdetail {[self] connect TLS: $host $port}
		set state tls_connect
		package require tls
		::tls::socket -async {*}$sockopts $host $port  ;# create SSL socket
	    }
	} socket eo] || [catch {
	    # condition the socket
	    Debug.HTTPdetail {[self] condition: $socket}
	    set state condition
	    chan configure $socket -blocking 1 -buffering none -encoding binary -translation {crlf binary}
	}]} {
	    set reason $socket
	    Debug.HTTP {[self] $state failed: $reason ($eo)}
	    variable justcontent
	    if {!$justcontent} {
		{*}$consumer [list X-type FAILED X-state $state X-reason $reason X-url $url X-object [self]]
	    }
	    return [list $socket $eo]
	}
    }

    # HTTP class method to create and run an HTTP pipeline
    # returns an object to manage the pipeline, or "" if it's closed
    self method run {url consumer args} {
	Debug.HTTP {run url:$url consumer:$consumer args:($args)}
	set object [my new $url $consumer {*}$args]

	$object connect		;# tcp connect to server
	$object start_reader	;# prepare to read responses

	# generate HTTP transactions
	if {[$object start_writer]} {
	    return ""		;# writer has failed, or completed
	} else {
	    return $object	;# writer is ready to go
	}
    }

    # HTTP class method to create and run a named HTTP pipeline
    self method runas {name url consumer args} {
	Debug.HTTP {runas name:$name url:$url consumer:$consumer args:($args)}
	set object [my create $name $url $consumer {*}$args]

	$object connect	;# tcp connect to server
	$object start_reader	;# prepare to read responses

	# generate HTTP transactions
	if {[$object start_writer]} {
	    # pipeline writer has failed, or completed
	    # we can't return a named command for it.
	    error "writer complete: [$object reason]"
	} else {
	    # pipeline is ready to go
	    return $object
	}
    }
}

if {[info exists argv0] && ($argv0 eq [info script])} {
    catch {Debug on HTTP 10}
    proc echo {arg} {
	puts "ECHO: $arg"
	lassign $arg op
	if {$op eq "CLOSED"} {
	    global done
	    #set done 1
	}
    }

    catch {http://1023.1024.1025.0126:8080/ echo}	;# a bad url
    set obj [http://localhost:8080/wub/ echo get /]	;# get a couple of URLs
    http://www.google.com.au/ echo justcontent 1	;# just get the content, not the dict
    puts stderr "OBJ: $obj"
    $obj get /wub/?A=1&B=2 echo
    $obj get http://localhost:8080/ echo

    set fd [open [info script]]; set source [read $fd]; close $fd
    if {[catch {::zlib adler32 $source} crc]} {
	puts stderr "No Adler32 - no source fetch"
    } elseif {[catch {package require fileutil}]} {
	puts stderr "No fileutil - no source fetch"
    } else {
	http://wub.googlecode.com/svn/trunk/Client/HTTP.tcl {set ::source} justcontent 1	;# fetch the latest HTTP.tcl

1	vwait ::source
	set source [subst -nocommands -novariables $source]
	puts stderr "Fetched [string length $source] bytes of source for HTTP.tcl"
	if {![catch {::zlib adler32 $source} crc2]} {
	    if {$crc ne $crc2} {
		puts stderr "There seems to be a newer version of HTTP.tcl"
		if {[lsearch $argv -autoupdate] != -1} {
		    puts stderr "Auto-updating HTTP.tcl in-place"
		    set this [info script]
		    if {![catch {fileutil::writeFile -- $this.new $source} e eo]} {
			file rename -force $this $this.bak
			file rename -force $this.new $this
		    } else {
			puts stderr "writing $this failed: $e ($eo)"
		    }
		}
	    } else {
		puts stderr "You seem to have the most current version of HTTP.tcl"
	    }
	}
    }

    vwait ::forever
}
