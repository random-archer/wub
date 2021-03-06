# ReCAPTCHA.tcl - a domain for recaptcha (http://recaptcha.net/)

package require TclOO
namespace import oo::*

package require Debug
Debug define recaptcha 10

package require HTTP
package provide ReCAPTCHA 1.0

set ::API(Domains/ReCAPTCHA) {
    {ReCAPTCHA interface
	=== Example: recaptcha on a page ===
	Nub domain /rc/ {ReCAPTCHA ::rc} public YOUR_PUBLIC_KEY private YOUR_PRIVATE_KEY

	Nub code /recap/ {
	    set r [jQ form $r .autoform target '#result']	;# optional jQ
	    set r [Http NoCache $r]	;# don't cache captchas

	    # everything from here is content:
	    <div> [subst {
		[::rc form class autoform]
		[<div> id result {}]
	    }]
	}
    }
}

class create ::ReCAPTCHA {


    method /validate {r id recaptcha_challenge_field recaptcha_response_field args} {
	if {![dict exists $resumption $id]} {
	    return [Http Ok $r "ReCAPTCHA is stale." text/plain]
	}
	lassign [dict get $resumption $id] pass fail
	dict unset resumption $id

	set entity [Query encodeL privatekey $private remoteip [dict get $r -ipaddr] challenge $recaptcha_challenge_field response $recaptcha_response_field]

	set V [HTTP run http://api-verify.recaptcha.net/ [lambda {r a pass_script fail_script v} {
	    set args $a
	    set result [split [dict get $v -content] \n]
	    Debug.recaptcha {ReCAPTCHA validation: $result}


	    set pass [lindex $result 0]
	    if {![string is boolean -strict $pass]} {
		return [Http ServerError $r "ReCAPTCHA Failed to Reply Sensibly."]
	    }


	    if {$pass} {
		Debug.recaptcha {ReCAPTCHA passed}
		lappend pass_script $r $a
		set r [uplevel #0 $pass_script]
	    } else {
		Debug.recaptcha {ReCAPTCHA failed}
		lappend fail_script $r $a
		set r [uplevel #0 $fail_script]
	    }
	    return [Httpd Resume $r]
	} $r $args $pass $fail] post [list /verify $entity content-type application/x-www-form-urlencoded] close]

	return [Httpd Suspend $r 100000]
    }

    method default_pass { req params } {
	return [Http Ok $req "Passed ReCAPTCHA" text/plain]
    }

    method default_fail { req params } {
	return [Http Ok $req "Failed ReCAPTCHA" text/plain]
    }

    method form {args} {
	set theme white
	set class {}
	set before {}	;# pre-recaptcha form content
	set after {}	;# post-recaptcha form content
	set pass [namespace code {my default_pass}]
	set fail [namespace code {my default_fail}] 
	dict for {n v} $args {
	    set $n $v
	}
	if {$class ne ""} {
	    set class [list class $class]
	}

	Debug.recaptcha {form: $pass $fail}
	dict set resumption [incr id] [list $pass $fail]
	Debug.recaptcha {resumption: $resumption - [file join $mount validate]/}

	return [<form> recapture {*}$class action [file join $mount validate]/ [subst {
	    $before
	    [<hidden> id $id]
	    <script type='text/javascript'> var RecaptchaOptions = {theme : '$theme'}; </script>
	    <script type='text/javascript' src='http://api.recaptcha.net/challenge?k=$public'> </script>
	    $after
	}]]
    }
    #[<noscript> [subst {
    #		[<iframe> src http://api.recaptcha.net/noscript?k=$public height 300 width 500 frameborder 0 {}]
    #		[<br>]
    #		[<textarea> recaptcha_challenge_field rows 3 cols 40 {}]
    #		[<hidden> recaptcha_response_field manual_challenge]
    #	    }]]

    method / {r} {
	error "Called / in ReCAPTCHA.  This is not useful."
    }

    mixin Direct
    variable mount resumption id public private

    method keys {args} {
	foreach n {public private} {
	    if {[dict exists $args $n]} {
		set $n [dict get $args $n]
	    }
	}
    }

    constructor {args} {
	set resumption {}
	set id 0
	set mount ""
	variable {*}[Site var? ReCAPTCHA]	;# allow .ini file to modify defaults

	foreach {n v} $args {
	    set $n $v
	}
	if {$public eq "" || $private eq ""} {
	    error "ReCAPTCHA requires a public and private key for this domain, available here: http://recaptcha.net/whyrecaptcha.html"
	}
    }
}

if {0} {
    # example of use
    package require ReCAPTCHA
    Nub domain /rc/ ReCAPTCHA public YOUR_PUBLIC_KEY private YOUR_PRIVATE_KEY

    Nub code /recap/ {
	set r [jQ form $r .autoform target '#result']
	set r [Http NoCache $r]

	# everything from here is content:
	<div> [subst {
	    [[lindex [info class instances ::ReCAPTCHA] 0] form class autoform]
	    [<div> id result {}]
	}]
    }

    proc my_recaptcha_pass {req params} {
	return [Http Ok $req "Passed ReCAPTCHA ($params)" text/plain]
    }

    Nub code /recap1/ {
	set r [jQ form $r .autoform target '#result']
	set r [Http NoCache $r]

	# everything from here is content:
	<div> [subst {
	    [[lindex [info class instances ::ReCAPTCHA] 0] form class autoform before [<text> field default] after [<submit> ok] pass my_recaptcha_pass]
	    [<div> id result {}]
	}]
    }
}
