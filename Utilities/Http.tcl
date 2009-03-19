# Http.tcl - useful utilities for an Http server.
#
# Contains procs to generate most useful HTTP response forms.

package require ip
package require Html
package require Url

package provide Http 2.1

proc Trace {{skip 1}} {
    set result {}
    for {set level [expr [info level] - $skip]} {$level >= 0} {incr level -1} {
	lappend result [info level $level]
    }
    return $result
}

# translation -- 
#
#	fconfigure the connected socket into a given mode
#
# Arguments:
#	args	additional args to fconfigure
#
# Side Effects:
#	sets the connected socket to the given mode

proc translation {sock args} {
    set additional {}
    for {set i 0} {$i < [llength $args]} {incr i} {
	set a [lindex $args $i]
	switch -glob -- $a {
	    -r* {
		incr i
		set rmode [lindex $args $i]
	    }
	    -w* {
		incr i
		set wmode [lindex $args $i]
	    }
	    default {
		lappend additional $a
	    }
	}
    }

    lassign [fconfigure $sock -translation] crm cwm

    if {[info exists rmode] && ($crm ne $rmode)} {
	Debug.socket {$sock read mode to $rmode} 20
    } else {
	set rmode $crm
    }

    if {[info exists wmode] && ($cwm ne $wmode)} {
	Debug.socket {$sock write mode to $wmode} 20
    } else {
	set wmode $cwm
    }

    fconfigure $sock -translation [list $rmode $wmode] {*}$additional
    Debug.socket {MODE: $rmode $wmode} 20
}

namespace eval Http {
    # HTTP error codes and default textual interpretation
    variable Errors
    array set Errors {
	1 "Informational - Request received, continuing process"
	100 Continue
	101 "Switching Protocols"

	2 "Success - received, understood, and accepted"
	200 OK
	201 Created
	202 Accepted
	203 "Non-Authoritative Information"
	204 "No Content"
	205 "Reset Content"
	206 "Partial Content"

	3 "Redirection - Further action needed"
	300 "Multiple Choices"
	301 "Moved Permanently"
	302 "Found"
	303 "See Other"
	304 "Not Modified"
	305 "Use Proxy"
	307 "Temporary Redirect"

	4 "Client Error - request bad or cannot be fulfilled"
	400 "Bad Request"
	401 "Unauthorized"
	402 "Payment Required"
	403 "Forbidden"
	404 "Not Found"
	405 "Method Not Allowed"
	406 "Not Acceptable"
	407 "Proxy Authentication Required"
	408 "Request Time-out"
	409 "Conflict"
	410 "Gone"
	411 "Length Required"
	412 "Precondition Failed"
	413 "Request Entity Too Large"
	414 "Request-URI Too Large"
	415 "Unsupported Media Type"
	416 "Requested range not satisfiable"
	417 "Expectation Failed"

	5 "Server Error - Server failed to fulfill an apparently valid request"
	500 "Internal Server Error"
	501 "Not Implemented"
	502 "Bad Gateway"
	503 "Service Unavailable"
	504 "Gateway Time-out"
	505 "HTTP Version not supported"
    }

    # categorise headers
    variable headers
    variable notmod_headers {
	date expires cache-control vary etag content-location
    }

    # set of request-only headers
    variable rq_headers {
	accept accept-charset accept-encoding accept-language authorization
	expect from host if-match if-modified-since if-none-match if-range
	if-unmodified-since max-forwards proxy-authorization referer te
	user-agent keep-alive cookie via
    }
    foreach n $rq_headers {
	set headers($n) rq
    }

    # set of response-only headers
    variable rs_headers {
	accept-ranges age etag location proxy-authenticate retry-after
	server vary www-authenticate
    }
    foreach n $rs_headers {
	set headers($n) rs
    }

    # set of entity-only headers
    variable e_headers {
	allow content-encoding content-language content-length 
	content-location content-md5 content-range content-type
	expires last-modified cache-control connection date pragma
	trailer transfer-encoding upgrade warning
    }
    foreach n $e_headers {
	set headers($n) e
    }

    # clf - common log format
    proc clf {r} {
	lappend line [dict get $r -ipaddr]	;# remote IP
	lappend line - -	;# we don't do user names

	# receipt time of connection
	lappend line \[[clock format [dict get $r -received_seconds] -format "%d/%b/%Y:%T %Z"]\]

	# first line of request
	lappend line \"[dict get? $r -header]\"

	# status we returned to it
	lappend line [dict get $r -code]

	# content byte length
	lappend line [string length [dict get? $r -content]]

	# referer, useragent, cookie, if any
	lappend line \"[dict get? $r referer]\"
	lappend line \"[dict get? $r user-agent] ([dict get? $r -ua_class])\"
	lappend line \"[dict get? $r cookie]\"

	return [join $line]
    }

    # map http error code to human readable message
    proc ErrorMsg {code} {
	variable Errors
	if {[info exist Errors($code)]} {
	    return $Errors($code)
	} else {
	    return "Error $code"
	}
    }

    # return an HTTP date
    proc DateInSeconds {date} {
	if {[string is integer -strict $date]} {
	    return $date
	} elseif {[catch {clock scan $date \
			-format {%a, %d %b %Y %T GMT} \
			-gmt true} result eo]} {
	    #error "DateInSeconds '$date', ($result)"
	    return 0	;# oldest possible date
	} else {
	    return $result
	}
    }

    # return an HTTP date
    proc Date {{seconds ""}} {
	if {$seconds eq ""} {
	    set seconds [clock seconds]
	}

	return [clock format $seconds -format {%a, %d %b %Y %T GMT} -gmt true]
    }

    # return the current time and date in HTTP format
    proc Now {} {
	return [clock format [clock seconds] -format {%a, %d %b %Y %T GMT} -gmt true]
    }

    # modify response to indicate that content is a file (NB: not working)
    proc File {rsp path {ctype ""}} {
	set path [file normalize $path]
	dict set rsp -fd [::open $path r]
	dict set rsp -file $path

	if {$ctype eq ""} {
	    dict set rsp content-type [Mime type $path]
	} else {
	    dict set rsp content-type $ctype
	}

	dict set rsp -code 200
	dict set rsp -rtype File
	return $rsp
    }

    # modify response so it will not be returned to client
    proc Suspend {rsp} {
	Debug.log {Suspend [dict merge $rsp {-content <elided>}]}
	dict set rsp -suspend 1
	return $rsp
    }

    # finally resume a suspended response
    proc Resume {rsp} {
	Debug.log {Resume [dict merge $rsp [list -content "<elided>[string length [dict get? $rsp -content]]"]]}
	catch {dict unset rsp -suspend}
	dict set rsp -resumed 1
	if {[catch {Responder post $rsp} r eo]} { ;# postprocess response
	    set rsp [Http ServerError $rsp $r $eo]
	} else {
	    set rsp $r
	}
	::Send $rsp
    }

    # modify response to indicate that the content is a cacheable file
    proc CacheableFile {rsp path {ctype ""}} {
	set path [file normalize $path]

	# read the file
	set fd [::open $path r]
	chan configure $fd -translation binary
	dict set rsp -content [read $fd]
	close $fd

	dict set rsp -file $path

	set mtime [file mtime $path]
	dict set rsp -modified $mtime
	dict set rsp last-modified [Date $mtime]

	if {$ctype eq ""} {
	    # calculate content-type using mime guessing
	    dict set rsp content-type [Mime type $path]
	} else {
	    dict set rsp content-type $ctype
	}

	# allow server caching
	set rsp [Http Depends $rsp [file normalize $path]]

	dict set rsp -code 200
	dict set rsp -rtype CacheableFile

	#catch {dict unset rsp -content}
	return $rsp
    }

    # record a dependency in a response
    proc Depends {rsp args} {
	catch {dict unset rsp -dynamic}
	dict lappend rsp -depends {*}$args
	return $rsp
    }

    # modify an HTTP response to indicate that its contents may not be Cached
    proc NoCache {rsp} {
	dict set rsp cache-control "no-store, no-cache, must-revalidate, max-age=0, post-check=0, pre-check=0"; # HTTP/1.1
	dict set rsp expires "Sun, 01 Jul 2005 00:00:00 GMT"	;# deep past
	dict set rsp pragma "no-cache"	;# HTTP/1.0
	dict set rsp -dynamic 1
	catch {dict unset rsp -modified}
	catch {dict unset rsp -depends}
	#catch {dict unset rsp last-modified}
	return $rsp
    }

    # modify an HTTP response to indicate that its contents may be Cached
    proc Cache {rsp {age 0} {realm "public"}} {
	if {[string is integer -strict $age]} {
	    # it's an age
	    if {$age != 0} {
		dict set rsp expires [Date [expr {[clock seconds] + $age}]]
	    } else {
		catch {dict unset rsp expires}
		catch {dict inset rsp -expiry}
	    }
	} else {
	    dict set rsp -expiry $age	;# remember expiry verbiage for caching
	    dict set rsp expires [Date [clock scan $age]]
	    set age [expr {[clock scan $age] - [clock seconds]}]
	}
	catch {dict unset rsp -dynamic}
	#dict set rsp cache-control "$realm, max-age=$age"
	dict set rsp cache-control $realm
	return $rsp
    }

    # modify an HTTP response to indicate that its contents must be revalidated
    proc DCache {rsp {age 0} {realm "public"}} {
	set rsp [Cache $rsp $age $realm]
	dict append rsp cache-control ", must-revalidate"
	return $rsp
    }

    # set default content type if needed
    proc setCType {rsp ctype} {
	# new ctype passed in?
	if {$ctype ne ""} {
	    dict set rsp content-type $ctype
	} elseif {![dict exists $rsp content-type]} {
	    dict set rsp content-type "text/html"
	}
	return $rsp
    }

    # modify an HTTP response to indicate that its contents is cacheable
    proc CacheableContent  {rsp mtime {content ""} {ctype ""}} {
	# cacheable content must have last-modified
	if {![dict exists $rsp last-modified]} {
	    dict set rsp last-modified [Date $mtime]
	}
	dict set rsp -modified $mtime

	if {![dict exists $rsp cache-control]} {
	    dict set rsp cache-control public
	}

	# Cacheable Content may have an -expiry clause
	if {[dict exists $rsp -expiry]} {
	    dict set rsp expires [Date [clock scan [dict get $rsp -expiry]]]
	}

	# new content passed in?
	if {$content ne ""} {
	    dict set rsp -content $content
	}

	set rsp [setCType $rsp $ctype]; # new ctype passed in?

	# new code passed in?
	if {![dict exists $rsp -code]} {
	    dict set rsp -code 200
	}

	dict set rsp -rtype CacheableContent	;# tag the response type
	return $rsp
    }

    # construct a generic Ok style response form
    proc OkResponse {rsp code rtype {content ""} {ctype ""}} {
	if {$content ne ""} {
	    dict set rsp -content $content
	} elseif {![dict exists $rsp -content]} {
	    dict set rsp content-length 0
	}

	set rsp [setCType $rsp $ctype]; # new ctype passed in?

	dict set rsp -code $code
	dict set rsp -rtype Ok
	return $rsp
    }

    # construct an HTTP Ok response
    proc Ok {rsp {content ""} {ctype ""}} {
	if {[dict exists $rsp -code]} {
	    set code [dict get $rsp -code]
	} else {
	    set code 200
	}
	return [OkResponse $rsp $code Ok $content $ctype]
    }

    # construct an HTTP Ok response of dynamic type (turn off caching)
    proc Ok+ {rsp {content ""} {ctype "x-text/html-fragment"}} {
	if {[dict exists $rsp -code]} {
	    set code [dict get $rsp -code]
	} else {
	    set code 200
	}
	return [OkResponse [Http NoCache $rsp] $code Ok $content $ctype]
    }

    # construct an HTTP passthrough response
    # this is needed if we already have a completed response and just want to
    # substitute content.  [Http Ok] does too much.
    proc Pass {rsp {content ""} {ctype ""}} {
	if {![dict exists $rsp -code]} {
	    dict set rsp -code 200
	}
	return [OkResponse $rsp [dict get $rsp -code] Ok $content $ctype]
    }

    # construct an HTTP Created response
    proc Created {rsp location} {
	dict set rsp -code 201
	dict set rsp -rtype Created
	dict set rsp location $location	;# location of created entity

	# unset the content components
	catch {dict unset rsp -content}
	catch {dict unset rsp content-type}
	dict set rsp content-length 0

	dict set rsp -dynamic 1	;# prevent caching
	dict set rsp -raw 1	;# prevent conversion

	return $rsp
    }

    # construct an HTTP Accepted response
    proc Accepted {rsp {content ""} {ctype ""}} {
	return [OkResponse $rsp 202 Accepted $content $ctype]
    }

    # construct an HTTP NonAuthoritative response
    proc NonAuthoritative {rsp {content ""} {ctype ""}} {
	return [OkResponse $rsp 203 NonAuthoritative $content $ctype]
    }

    # construct an HTTP NoContent response
    proc NoContent {rsp} {
	foreach el {content-type -content -fd} {
	    catch [list dict unset rsp $el]
	}

	dict set rsp -code 204
	dict set rsp -rtype NoContent

	return $rsp
    }

    # construct an HTTP ResetContent response
    proc ResetContent {rsp {content ""} {ctype ""}} {
	return [OkResponse $rsp 205 ResetContent $content $ctype]
    }

    # construct an HTTP PartialContent response
    # TODO - actually support this :)
    proc PartialContent {rsp {content ""} {ctype ""}} {
	return [OkResponse $rsp 206 PartialContent $content $ctype]
    }

    # set the title <meta> tag, assuming we're returning fragment content
    proc title {r title} {
	if {[string length $title] > 80} {
	    set title [string range $title 0 80]...
	}
	dict set r -title $title
	return $r
    }

    # sysPage - generate a 'system' page
    proc sysPage {rsp title content} {
	dict set rsp content-type "x-text/system"
	set rsp [title $rsp $title]
	dict set rsp -content "[<h1> $title]\n$content"
	return $rsp
    }

    # construct an HTTP response containing a server error page
    proc ServerError {rsp message {eo ""}} {
	Debug.error {Server Error: '$message' ($eo)} 2
	set content ""
	if {[catch {
	    if {$eo ne ""} {
		append table [<tr> [<th> "Error Info"]] \n
		dict for {n v} $eo {
		    append table [<tr> "[<td> $n] [<td> [armour $v]]"] \n
		}
		append content [<table> border 1 width 80% $table] \n
	    }
	    
	    catch {append content [<p> "Caller: [armour [info level -1]]"]}
	    set message [armour $message]
	    catch {dict unset rsp expires}
	    if {[string length $message] > 80} {
		set tmessage [string range $message 0 80]...
	    } else {
		set tmessage $message
	    }

	    # make this an x-system type page
	    set rsp [sysPage $rsp "Server Error: $tmessage" [subst {
		[<p> [tclarmour $message]]
		<hr>
		[tclarmour $content]
		<hr>
		[tclarmour [dump $rsp]]
	    }]]
 
	    dict set rsp -code 500
	    dict set rsp -rtype Error
	    dict set rsp -dynamic 1
	    
	    # Errors are completely dynamic - no caching!
	    set rsp [NoCache $rsp]
	} r1 eo1]} {
	    Debug.error {Recursive ServerError $r1 ($eo1) from '$message' ($eo)}
	} else {
	    Debug.http {ServerError [dumpMsg $rsp 0]}
	}

	return $rsp
    }

    # construct an HTTP NotImplemented response
    proc NotImplemented {rsp {message ""}} {
	if {$message eq ""} {
	    set message "This function not implemented"
	} else {
	    append message " - Not implemented."
	}

	set rsp [sysPage $rsp "Not Implemented" [<p> $message]]

	dict set rsp -code 501
	dict set rsp -rtype NotImplemented
	dict set rsp -error $message

	return $rsp
    }

    # construct an HTTP Unavailable response
    proc Unavailable {rsp message {delay 0}} {
	set rsp [sysPage $rsp "Service Unavailable" [<p> $message]]

	dict set rsp -code 503
	dict set rsp -rtype Unavailable
	if {$delay > 0} {
	    dict set rsp retry-after $delay
	}
	return $rsp
    }

    proc GatewayTimeout {rsp message} {
	set rsp [sysPage $rsp "Service Unavailable" [<p> $message]]

	dict set rsp -code 504
	dict set rsp -rtype GatewayUnavailable

	return $rsp
    }

    # construct an HTTP Bad response
    proc Bad {rsp message {code 400}} {
	set rsp [sysPage $rsp "Bad Request" [<p> $message]]

	dict set rsp -code $code
	dict set rsp -rtype Bad
	dict set rsp -error $message

	return $rsp
    }

    # construct an HTTP NotFound response
    proc NotFound {rsp {content ""} {ctype "x-text/system"}} {
	if {$content ne ""} {
	    dict set rsp -content $content
	    dict set rsp content-type $ctype
	} elseif {![dict exists $rsp -content]} {
	    set uri [dict get $rsp -uri]
	    set rsp [sysPage $rsp "$uri Not Found" [<p> "The entity '$uri' doesn't exist."]]
	}

	dict set rsp -code 404
	dict set rsp -rtype NotFound

	return $rsp
    }

    # construct an HTTP Forbidden response
    proc Forbidden {rsp {content ""} {ctype "x-text/html-fragment"}} {
	if {$content ne ""} {
	    dict set rsp -content $content
	    dict set rsp content-type $ctype
	} elseif {![dict exists $rsp -content]} {
	    set rsp [sysPage $rsp "Access Forbidden" [<p> "You are not permitted to access this page."]]
	}

	dict set rsp -code 403
	dict set rsp -rtype Forbidden

	return $rsp
    }

    proc BasicAuth {realm} {
	return "Basic realm=\"$realm\""
    }

    proc Credentials {r args} {
	if {![dict exists $r authorization]} {
	    return ""
	}
	set cred [join [lassign [split [dict get $r authorization]] scheme]]
	package require base64
	if {[llength $args]} {
	    return [{*}$args $userid $password]
	} else {
	    return [split [::base64::decode $cred] :]
	}
    }

    proc CredCheck {r checker} {
	lassign [Credentials $r] userid password
	return [{*}$checker $userid $password]
    }

    # construct an HTTP Unauthorized response
    proc Unauthorized {rsp {challenge ""} {content ""} {ctype "x-text/html-fragment"}} {
	if {$challenge ne ""} {
	    dict set rsp WWW-Authenticate $challenge
	}
	if {$content ne ""} {
	    dict set rsp -content $content
	    dict set rsp content-type $ctype
	} elseif {![dict exists $rsp -content]} {
	    set rsp [sysPage $rsp Unauthorized [<p> "You are not permitted to access this page."]]
	}

	dict set rsp -code 401
	dict set rsp -rtype Unauthorized

	return $rsp
    }

    # construct an HTTP Conflict response
    proc Conflict {rsp {content ""} {ctype "x-text/system"}} {
	if {$content ne ""} {
	    dict set rsp -content $content
	    dict set rsp content-type $ctype
	} elseif {![dict exists $rsp -content]} {
	    set rsp [sysPage $rsp Conflict [<p> "Conflicting Request"]]
	}

	dict set rsp -code 409
	dict set rsp -rtype Conflict
	return $rsp
    }

    # construct an HTTP PreconditionFailed response
    proc PreconditionFailed {rsp {content ""} {ctype "x-text/system"}} {
	if {$content ne ""} {
	    dict set rsp -content $content
	    dict set rsp content-type $ctype
	}

	dict set rsp -code 412
	dict set rsp -rtype PreconditionFailed
	return $rsp
    }

    # construct an HTTP NotModified response
    proc NotModified {rsp} {
	# remove content-related stuff
	foreach n [dict keys $rsp content-*] {
	    if {$n ne "content-location"} {
		dict unset rsp $n
	    }
	}

	# discard some fields
	Dict strip rsp transfer-encoding -chunked -content

	# the response MUST NOT include other entity-headers
	# than Date, Expires, Cache-Control, Vary, Etag, Content-Location
	set result [dict filter $rsp key -*]

	variable rq_headers
	set result [dict merge $result [Dict subset $rsp $rq_headers]]

	variable notmod_headers
	set result [dict merge $result [Dict subset $rsp $notmod_headers]]

	# tell the other end that this isn't the last word.
	if {0 && ![dict exists $result expires]
	    && ![dict exists $result cache-control]
	} {
	    dict set result cache-control "must-revalidate"
	}

	dict set result -code 304
	dict set result -rtype NotModified

	return $result
    }

    # internal redirection generator
    proc genRedirect {title code rsp to {content ""} {ctype "text/html"} args} {
	set to [Url redir $rsp $to {*}$args]

	if {$content ne ""} {
	    dict set rsp -content $content
	    dict set rsp content-type $ctype
	} else {
	    dict set rsp -content [<html> {
		[<head> {[<title> $title]}]
		[<body> {
		    [<h1> $title]
		    [<p> "The page may be found here: <a href='[armour $to]'>[armour $to]"]
		}]
	    }]
	    dict set rsp content-type "text/html"
	}

	if {0} {
	    if {![string match {http:*} $to]} {
		# do some munging to get a URL
		dict set rsp location $rsp [Url redir $rsp $to]
	    } else {
		dict set rsp location $to
	    }
	}

	dict set rsp location $to
	dict set rsp -code $code
	dict set rsp -rtype $title

	dict set rsp -dynamic 1	;# don't cache redirections

	return $rsp
    }

    # discover Referer of request
    proc Referer {req} {
	if {[dict exists $req referer]} {
	    return [dict get $req referer]
	} else {
	    return ""
	}
    }

    # construct an HTTP Redirect response
    proc Redirect {rsp {to ""} {content ""} {ctype "text/html"} args} {
	if {$to eq ""} {
	    set to [dict get $rsp -url]
	}
	return [Http genRedirect Redirect 302 $rsp $to $content $ctype {*}$args]
    }

    # construct a simple HTTP Redirect response with extra query
    proc Redir {rsp to args} {
	return [Http genRedirect Redirect 302 $rsp $to "" "" {*}$args]
    }

    # construct an HTTP Redirect response to Referer of request
    proc RedirectReferer {rsp {content ""} {ctype ""} args} {
	set ref [Referer $rsp]
	if {$ref eq ""} {
	    set ref /
	}
	return [Http genRedirect Redirect 302 $rsp $ref $content $ctype {*}$args]
    }

    # construct an HTTP Found response
    proc Found {rsp to {content ""} {ctype "text/html"} args} {
	return [Http genRedirect Redirect 302 $rsp $to $content $ctype {*}$args]
    }

    # construct an HTTP Relocated response
    proc Relocated {rsp to {content ""} {ctype "text/html"} args} {
	return [Http genRedirect Relocated 307 $rsp $to $content $ctype {*}$args]
    }
    
    # construct an HTTP SeeOther response
    proc SeeOther {rsp to {content ""} {ctype "text/html"} args} {
	return [Http genRedirect SeeOther 303 $rsp $to $content $ctype {*}$args]
    }

    # construct an HTTP Moved response
    proc Moved {rsp to {content ""} {ctype "text/html"} args} {
	return [Http genRedirect Moved 301 $rsp $to $content $ctype {*}$args]
    }

    
    # loadContent -- load a response's file content 
    #	used when the content must be transformed
    #
    # Arguments:
    #	rsp	a response dict
    #
    # Side Effects:
    #	loads the content of a response file descriptor
    #	Possibly close socket

    proc loadContent {rsp} {
	# if rsp has -fd content and no -content
	# we must read the entire file to convert it
	if {[dict exists $rsp -fd]} {
	    if {![dict exists $rsp -content]} {
		if {[catch {
		    set fd [dict get $rsp -fd]
		    fconfigure $fd -translation binary
		    read $fd
		} content eo]} {
		    # content couldn't be read - serious error
		    set rsp [Http ServerError $rsp $content $eo]
		} else {   
		    dict set rsp -content $content
		}

		if {![dict exists $rsp -fd_keep_open]} {
		    # user can specify fd is to be kept open
		    catch {close $fd}
		    dict unset rsp -fd
		} else {
		    seek $fd 0	;# re-home the fd
		}
	    }
	} elseif {![dict exists $rsp -content]} {
	    error "expected content"
	}

	return $rsp
    }

    # dump the context
    proc dump {req {short 1}} {
	catch {
	    set table [<tr> [<th> Metadata]]\n
	    foreach n [lsort [dict keys $req -*]] {
		if {$short && ($n eq "-content")} continue
		append table [<tr> "[<td> $n] [<td> [armour [dict get $req $n]]]"] \n
	    }
	    append c [<table> border 1 width 80% $table] \n
	    
	    set table [<tr> [<th> HTTP]]\n
	    foreach n [lsort [dict keys $req {[a-zA-Z]*}]] {
		append table [<tr> "[<td> $n] [<td> [armour [dict get $req $n]]]"] \n
	    }
	    append c [<table> border 1 width 80% $table] \n

	    set table [<tr> [<th> Query]]\n
	    array set q [Query flatten [Query parse $req]]
	    foreach {n} [lsort [array names q]] {
		append table [<tr> "[<td> [armour $n]] [<td> [armour $q($n)]]"] \n
	    }
	    append c [<table> border 1 width 80% $table] \n
	} r eo

	return $c
    }

    # add a Vary field
    proc Vary {rsp args} {
	foreach field $args {
	    dict set rsp -vary $field 1
	}
	return $rsp
    }

    # add a Vary field
    proc UnVary {rsp args} {
	foreach field $args {
	    catch {dict unset rsp -vary $field}
	}
	return $rsp
    }

    # add a Refresh meta-data field
    proc Refresh {rsp time {url ""}} {
	catch {dict unset rsp cache-control}
	if {$url == ""} {
	    dict set rsp refresh $time
	} else {
	    dict set rsp refresh "${time};url=$url"
	}
	return $rsp
    }

    # nonRouting - predicate to determine if an IP address is routable
    proc nonRouting? {ip} {
	return [expr {$ip eq ""
		      || $ip eq "unknown"
		      || [::ip::type $ip] ne "normal"
		  }]
    }

    # expunge - remove metadata from reply dict
    proc expunge {reply} {
	foreach n [dict keys $reply content-*] {
	    dict unset reply $n
	}

	# discard some fields
	Dict strip reply transfer-encoding -chunked -content
	return $reply
    }

    namespace export -clear *
    namespace ensemble create -subcommands {}
}
