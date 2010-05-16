Root {
    type Root
}

Type {
    type Type
}

Basic {
    type Type
}
Basic+Html {
    type Conversion
    content {
	# at the moment, we'll assume Basic is Html
	return [Http Ok $r [dict get $r -content] tuple/html]
    }
}

"Tcl Script" {
    type Type
    mime "Tcl Script"
    content {
	# evaluate tuple of "Tcl Script" as the result of its tcl evaluation
	set result [subst [dict get $r -content]]

	# determine the mime type of result
	if {[dict exists $r -mime]} {
	    set mime [string map {_ /} [dict get? $r -mime]]
	} else {
	    set mime [my getmime [dict get? $r -tuple]]
	}
	Debug.tupler {tcl script to '$mime' mime type content:($result)}
	return [Http Ok $r $result $mime]
    }
}

"Not Found" {
    type "Tcl Script"
    content {
	[<title> [string totitle "$kind error"]]
	[<h1> [string totitle "$kind error"]]
	[<p> "'$nfname' not found while looking for '$extra'"]
	[<p> "(Generated from [<a> href xray/Not%2BFound "Not Found"] page)"]
    }
}

Glob {
    type Type
    mime "Tcl Script"
    content {
	# search tuples for name matching glob, return a List
	set tuple [dict get $r -tuple]
	Debug.tupler {GLOB conversion: [dict size $r] ($tuple)}
	dict with tuple {
	    if {$mime ne "text"} {
		set search [my tuConvert $tuple tuple/text tuple/$mime]
	    } else {
		set search [dict get $r -content]
	    }
	}
	set search [string trim $search]
	set result [my globByName $search]
	
	Debug.tupler {GLOB search: '$search' -> ($result)}
	return [Http Ok $r $result tuple/list]
    }
}

Named+List {
    type Conversion
    mime "Tcl Script"
    content {
	# search tuples for name matching regexp, return a List
	set tuple [dict get $r -tuple]
	dict with tuple {
	    if {$mime ni {"basic text"}} {
		set search [my tuConvert $tuple tuple/text]
	    } else {
		set search [dict get $r -content]
	    }
	}
	set search [string trim $search]
	set result [my regexpByName $search]
	return [Http Ok $r $result tuple/list]
    }
}

Javascript+Html {
    type Conversion
    mime "Tcl Script"
    content {
	return [Http Ok $r [<script> [dict get $r -content]]] tuple/html]
    }
}

Javascript+Head {
    type Conversion
    mime "Tcl Script"
    content {
	return [Http Ok $r [<script> [dict get $r -content]]] tuple/head]
    }
}

CSS+Html {
    type Conversion
    mime "Tcl Script"
    content {
	return [Http Ok $r [<style> type text/css [dict get $r -content]] tuple/html]
    }
}

CSS+Head {
    type Conversion
    mime "Tcl Script"
    content {
	return [Http Ok $r [<style> type text/css [dict get $r -content]] tuple/head]
    }
}

ref+html {
    type Conversion
    mime "Tcl Script"
    content {
	set content [dict get $r -content]
	set mime [dict get $r -tuple mime]
	set id [dict get $r -tuple id]

	# each ref determines its referenced content's type
	switch -glob -- $mime {
	    css -
	    text/css {
		set content [<stylesheet> {*}$content]
		# should this be in an html body?
	    }

	    javascript -
	    */javascript {
		set content [<script> type text/javascript src {*}$content {}]
	    }

	    transclude/* {
		set content [<div> id $id class transclude href {*}$content]
	    }

	    image/* {
		set content [<img> id $id src {*}$content]
	    }

	    default {
		set content [<a> id $id href {*}$content]
	    }
	}
	return [Http Ok $r $content tuple/html]
    }
}

ref+head {
    type Conversion
    mime "Tcl Script"
    content {
	set content [dict get $r -content]
	set mime [dict get $r -tuple mime]
	set id [dict get $r -tuple id]

	switch -glob -- $mime {
	    css -
	    text/css {
		set content [<stylesheet> {*}$content]
	    }

	    javascript -
	    */javascript {
		set content [<script> type text/javascript src {*}$content {}]
	    }

	    default {
		return -code error -kind type -notfound $id "ref of type $mime has no rendering as Head"
	    }
	}

	return [Http Ok $r $content tuple/head]
    }
}

Dict {
    type Type
    content {
	# do some form checking on the dict
	if {[catch {dict size [dict get? $r -content]} e eo]} {
	    return [Http Ok $r [subst {
		[<h1> "Type error"]
		[<p> "'[armour [dict get $r -tuple name]]' is of Type 'Dict', however its content is not a properly-formed dictionary."]
		[<p> "Dictionaries are tcl lists with an even number of elements."]
		[<h2> Content:]
		[<pre> [armour [dict get? $r -content]]]
	    }] tuple/html]
	} else {
	    return [Http Pass $r]
	}
    }
}

List+Dict {
    type Conversion
    mime "Tcl Script"
    content {
	Debug.tupler {list conversion: [dict size $r] ($r)}
	# make a list into a Dict by making tuple name the key
	set result {}
	foreach v [dict get $r -content] {
	    set v [my fetch $v]
	    dict set result [dict get $v name] [dict set $v id]
	}
	return [Http Ok $r [join $result \n] tuple/dict]
    }
}

List+Html {
    type Conversion
    mime "Tcl Script"
    content {
	Debug.tupler {List to Html conversion: ([dict get $r -content])}
	set result ""
	foreach v [dict get $r -content] {
	    set v [my fetch $v]
	    set c [my tuConvert $v tuple/html]
	    Debug.tupler {List to Html: converted $v to ($c)}
	    append result [<li> id [dict get $v id] $c] \n
	}
	if {$result ne ""} {
	    set result [<ol> \n$result]\n
	}
	return [Http Ok $r $result tuple/html]
    }
}

Dict+Head {
    type Conversion
    mime "Tcl Script"
    content {
	Debug.tupler {Dict to Head conversion: [dict size $r] ($r)}
	set result {}
	dict for {n v} [dict get $r -content] {
	    set v [my fetch $v]
	    if {[dict get $v type] eq "ref"} {
		# rename refs so their dict-name is their reference
		set n [lindex [dict get $v content] 0]
	    }
	    if {[info exists $result $n]} continue
	    dict set result $n [my tuConvert $v tuple/head]
	}
	#Debug.tupler {dict conversion: ([dict get $r -content]) -> ($result)}
	dict set r -tuple mime "Tcl Dict"
	return [Http Pass $r $result tuple/head]
    }
}

Dict+Html {
    type Conversion
    mime "Tcl Script"
    content {
	Debug.tupler {Dict to Html conversion: [dict size $r] ($r)}
	# we prefer a tabular form, but could use dl instead
	set result {}
	set content 
	dict for {n v} [dict get $r -content] {
	    if {[dict exists $result $n]} continue
	    set v [my fetch $v]
	    set sub [my tuConvert $v tuple/html]
	    lappend result [<tr> "[<th> [armour $n]] [<td> [armour $sub]]"]
	}
	set result [<table> class sortable border 2 [join $result \n]]
	#Debug.tupler {dict conversion: ([dict get $r -content]) -> ($result)}
	return [Http Pass $r $result tuple/html]
    }
}

"Tcl Variable" {
    type Type
    mime "Tcl Script"
    content {
	# evaluate tuple of "Tcl Script" as the result variable resolution
	set mime [my getmime [dict get? $r -tuple]]

	set result [set [dict get $r -content]]
	Debug.tupler {Tcl Variable '$result' of type '$mime'}
	return [Http Ok $r $result $mime]
    }
}

"Tcl Dict" {
    type Type
    content {
	# do some form checking on the dict
	if {[catch {dict size [dict get? $r -content]} e eo]} {
	    return [Http Ok $r [subst {
		[<h1> "Type error"]
		[<p> "'[armour [dict get $r -tuple name]]' is of Type 'Tcl Dict', however its content is not a properly-formed dictionary."]
		[<p> "Dictionaries are tcl lists with an even number of elements."]
		[<h2> Content:]
		[<pre> [armour [dict get? $r -content]]]
	    }] tuple/html]
	} else {
	    return [Http Pass $r]
	}
    }
}

"Tcl Dict+Head" {
    type Conversion
    mime "Tcl Script"
    content {
	Debug.tupler {Tcl Dict to Head conversion: [dict size $r] ($r)}
	set result {}
	set content [dict get $r -content]
	dict for {n v} $content {
	    lappend result [<tr> "[<th> [armour $n]] [<td> [armour $v]]"]
	}
	set result [<table> class sortable border 2 [join $result \n]]
	#Debug.tupler {dict conversion: ([dict get $r -content]) -> ($result)}
	return [Http Pass $r $result tuple/html]
    }
}

"Tcl Dict+Html" {
    type Conversion
    mime "Tcl Script"
    content {
	Debug.tupler {Tcl Dict to Html conversion: [dict size $r] ($r)}
	# we prefer a tabular form, but could use dl instead
	set result {}
	set content [dict get $r -content]
	dict for {n v} $content {
	    lappend result [<tr> "[<th> [armour $n]] [<td> [armour $v]]"]
	}
	set result [<table> class sortable border 2 [join $result \n]]
	#Debug.tupler {dict conversion: ([dict get $r -content]) -> ($result)}
	return [Http Pass $r $result tuple/html]
    }
}

Text {
    type Type
}

Text+Html {
    type Conversion
    mime "Tcl Script"
    content {
	return [Http Ok $r [<pre> [dict get $r -content]] tuple/html]
    }
}

"example text" {
    type Text
    content "this is text/plain"
}

Uppercase+Text {
    type Conversion
    content {
	return [Http Pass $r [dict get $r -content] tuple/text]
    }
}

Uppercase {
    type Type
    content {
	return [Http Pass $r [string toupper [dict get $r -content]]]
    }
}

"Example Uppercase" {
    type Uppercase
    content "this is uppercase"
}

welcome {
    type "Tcl Script"
    content {
	[<h1> "Welcome to Tuple"]
	[Html ulinks {
	    "Test composition and Tcl Scripting" now
	    "Test Tcl Variable and Tcl Dict rendering" reflect
	    "Test Uppercase and text/plain" {Example+Uppercase}
	    "Test page not found" nothere
	    "XRay of Now page" xray/now
	}]
    }
}

now {
    type "Tcl Script"
    content {
	[<h1> Now]
	[<p> "[clock format [clock seconds]] is the time"]
	[<p> "This page is generated from a Tcl Script, and assembled from components for [<a> href xray/now%2Bstyle style] (which makes the header red) and [<a> href xray/now%2Btitle title] (which gives the page a title.)"]
	[<p> "The tuple underlying this may be viewed with the [<a> href xray/now "xray facility"]."]

	[<p> "Next step - Creole and Transclusion"]
    }
}

now+title {
    type Text
    content "A Demo Title"
}

now+style {
    type css
    content {
	h1 {color:red;}
    }
}

reflect {
    type "Tcl Variable"
    mime "Tcl Dict"
    content r
}

"Reflect Text" {
    type "Tcl Variable"
    mime Text
    content r
}

"Dict err" {
    type "Tcl Dict"
    content {this is not a properly formed dict}
}

"Glob Test" {
    type Glob
    mime text
    content {
	now+*
    }
}