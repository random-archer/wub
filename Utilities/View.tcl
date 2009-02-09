# View.tcl - TclOO Wrapper around Metakit
package require TclOO
namespace import oo::*

if {[info exists argv0] && ($argv0 eq [info script])} {
    lappend auto_path /usr/lib/${tcl_version}/Mk4tcl ../extensions/
}

package require Mk4tcl
if {[info commands ::Debug] eq {}} {
    proc Debug.view {args} {}
} else {
    Debug off view 10
}

package provide View 3.0

class create ViewSyn {
    method incr {index field {qty 1}} {
	Debug.view {mixin incr}
	return [[my parent] incr [[my view] get $index index] $field $qty]
    }

    # lappend to a field
    method lappend {index field args} {
	if {[llength $args] == 1} {
	    set args [lindex $args 0]
	}
	return [[my parent] lappend [[my view] get $index index] $field {*}$args]
    }

    # append values to field as dict/value pairs
    method dlappend {index field args} {
	if {[llength $args] == 1} {
	    set args [lindex $args 0]
	}
	return [[my parent] lappend [[my view] get $index index] $field {*}$args]
    }

    # info - return view's layout
    method info {args} {
	set result [[my parent] info {*}$args]
	Debug.view {mixin info [self] ([[my view] info]) -> $result}
	return $result
    }

    method get {index args} {
	if {[llength $args] == 1} {
	    set args [lindex $args 0]
	}
	Debug.view {MIXIN get [my view]!$index ([[my view] info]) (which is [my parent]/[[my view] get $index index]) $args}
	return [[my parent] get [[my view] get $index index] {*}$args]
    }

    # set a field's value
    method set {index args} {
	if {[llength $args] eq 1} {
	    set args [lindex $args 0]
	}
	Debug.view {MIXIN [my view] set $index keys: '[dict keys $args]'}
	return [[my parent] get [[my view] get $index] {*}$args]
    }

    method all {script} {
	set view [my view]
	set mysize [expr {[$view size] - 1}]
	set indices {}
	for {set i $mysize} {$i >= 0} {incr i -1} {
	    set record [$view get $i index]
	    Debug.view {MIXIN $view}
	    lappend indices [$view get $i index]
	}
	set result [uplevel 1 [my parent] foreach [list $script] {*}$indices]
	Debug.view {MIXIN $view [$view size] ([$view info]) all -> [my parent]/[[my parent] view] foreach $indices -> $result }
	return $result
    }

    method select {args} {
	error "select on indexed synthetic view unsupported - try sorting your selected set"
    }
}

class create ViewLogger {
    variable logger
    set logger {}

    method logger {{l ""}} {
	if {$logger ne ""} {
	    set logger $l
	}
	return $logger
    }

    method set {index args} {
	set result [next $index {*}$args]
	{*}$logger set [my name] $index $args [my get $index]
	return $result
    }

    method insert {index args} {
	set result [next $index {*}$args]
	if {$index eq "end"} {
	    set index $result
	}
	{*}$logger insert [my name] $index $args
	return $result
    }

    method delete {args} {
	set result [next {*}$args]
	{*}$logger delete [my name] $args
	return $result
    }
}

class create View {
    # incr a field
    method incr {index field {qty 1}} {
	set val [expr {[my get $index $field] + $qty}]
	my set $index $field $val
	Debug.view {incr $view!$index $field $qty -> $val}
	return $val
    }

    # lappend to a field
    method lappend {index field args} {
	if {[llength $args] == 1} {
	    set args [lindex $args 0]
	}
	Debug.view {lappend $view!$index $field $args}
	set value [my get $index $field]
	lappend value {*}$args
	return [my set $index $field $value]
    }

    # append values to field as dict/value pairs
    method dlappend {index field args} {
	if {[llength $args] == 1} {
	    set args [lindex $args 0]
	}
	Debug.view {dlappend $view!$index $field $args}
	return [my set $index $field [dict merge [my get $index $field] $args]]
    }

    # get a field's value
    method get {index args} {
	if {[llength $args] == 1} {
	    set args [lindex $args 0]
	}
	Debug.view {get $view!$index $args}
	return [$view get $index {*}$args]
    }

    # set a field's value
    method set {index args} {
	if {[llength $args] eq 1} {
	    set args [lindex $args 0]
	}
	Debug.view {$view set $index keys: '[dict keys $args]'}
	return [$view set $index {*}$args]
    }

    # return a view's contents as a list
    method list {args} {
	set _args $args
	set __result {}
	my all {
	    set _props {}
	    foreach __v $_args {
		lappend _props [set $__v]
	    }
	    lappend __result $_props
	}
	return $__result
    }

    # return a view's content as a nested dict
    method dict {_key args} {
	if {[llength $args] == 1} {
	    set args [lindex $args 0]
	}
	if {![llength $args]} {
	    set _args [dict keys [my info2dict]]	;# get the props
	} else {
	    set _args $args
	}
	set _subv [dict keys [dict filter [my info2dict] value V]]	;# get the subviews
	set __result {}
	my all {
	    set _props {}
	    foreach __v $_args {
		if {$__v in $_subv} {
		    lappend props $__v [[lambda {_v} {
			set _subv [dict keys [dict filter [$_v info2dict] value V]]
			set _props {}
			$_v all {
			    foreach _el in $_v {
				if {$_el in $_subv} continue
				lappend _props $_el [set $_el]
			    }
			}
			return $_props
		    }] $__v]
		} else {
		    lappend _props $__v [set $__v]
		}
	    }
	    lappend __result [set $_key] $_props
	}
	return $__result
    }

    # open all the subviews of the index
    method subviews {{index -1}} {
	set result {}
	set subviews [dict keys [dict filter [my info2dict] value V]]
	if {$index < 0} {
	    return $subviews
	} else {
	    foreach sv $subviews {
		dict set result $sv [my open $index $sv]
	    }
	    Debug.view {subview $index $result}
	    return $result
	}
    }

    method "loop" {args} {
	
    }

    # lselect - perform a select over view yielding a list of indices
    method lselect {args} {
	if {[llength $args] eq 1} {
	    set args [lindex $args 0]
	}

	if {![info exists name]} {
	    [my select {*}$args] as v
	    set vs [$v size]
	    Debug.view {lselect ($args) over synthetic view [self] [my info] -> $v: [$v info] with $vs results}
	    set r {}
	    for {set i 0} {$i < $vs} {incr i} {
		lappend r [[$v view] get $i index]
	    }
	    #$v destroy
	} else {
	    set r [::mk::select $db.$name {*}$args]
	}
	
	Debug.view {[self] lselect $args -> $r}
	return $r
    }

    # dselect - return a select as a dict of records
    method dselect {args} {
	if {[llength $args] eq 1} {
	    set args [lindex $args 0]
	}
	Debug.view {dselect $view $args}
	set result {}
	foreach index [my lselect {*}$args] {
	    dict set result [my get $index]
	}
	return $result
    }

    # select - return a view which is a result of the select criteria
    method select {args} {
	if {[llength $args] eq 1} {
	    set args [lindex $args 0]
	}

	if {[lsearch $args -sort] > -1 || [lsearch $args -rsort] > -1} {
	    set type {}	;# a select with a sort is conformant with the parent
	} else {
	    set type {type index}
	}
	set result [View new [$view select {*}$args] parents [self] {*}$type]
	Debug.view {[self]: $view select ($args) -> $result/[$result size] ([$result info]) }
	return $result
    }

    # info - return view's layout
    method info {args} {
	return [$view info {*}$args]
    }

    # return view info as a dict
    method info2dict {args} {
	set result {}
	foreach el [split [$view info {*}$args]] {
	    set v S
	    lassign [split $el :] n v
	    dict set result $n $v
	}
	return $result
    }

    # update selected rows with a script's values
    method update {select script args} {
	# construct a list of updateable props, default all
	if {[llength $args] == 1} {
	    set args [lindex $args 0]
	}
	if {$args eq {}} {
	    set args [my names]
	}

	# make the list an identity map over selected keys
	set kv {}
	foreach arg $args {
	    lappend kv $arg $arg
	}
	set vn __update__[namespace tail [self]]
	upvar $vn uv
	foreach index [my lselect {*}$select] {
	    set uv [my get $index]
	    switch [catch {
		uplevel 1 dict update __update__ $kv [list $script]
	    } result eo] {
		1 {# error - re-raise the error
		    return -options $eo $result
		}
		3 {break}
		4 {continue}
		2 {return $result}

		default {# normal
		    my set $index {*}[dict filter $uv script {k v} {
			expr {$k in $args}
		    }]
		}
	    }
	}
    }

    # subst - run subst over fields from selected records
    method subst {text args} {
	if {[llength $args] eq 1} {
	    set args [lindex $args 0]
	}
	set vn __with__[namespace tail [self]]
	upvar $vn uv
	set results {}
	foreach index [my lselect {*}$args] {
	    set uv [my get $index]
	    dict set uv "" $index
	    switch [catch {
		uplevel 1 dict with $vn [list [list ::subst $text]]
	    } result eo] {
		1 {# error - re-raise the error
		    return -options $eo $result
		}
		3 {break}
		4 {continue}
		2 {return $result}

		default {# normal
		    lappend results $index $result
		}
	    }
	}
	return $results
    }

    method local {} {
	set varname [string map {: _} [self]]
	#puts stderr "LOCAL $varname"
	upvar $varname lifetime
	trace add variable lifetime unset "catch {[self] destroy};#"
    }

    method as {varname} {
	upvar $varname lifetime
	set lifetime [self]
	trace add variable lifetime {write unset} "catch {[self] destroy};#"
    }

    method foreach {script args} {
	if {[llength $args] eq 1} {
	    set args [lindex $args 0]
	}
	Debug.view {[self] foreach over ($args)}
	set vn __all__[namespace tail [self]]
	upvar $vn uv
	set results {}
	foreach index $args {
	    set uv [my get $index]

	    # create subviews
	    foreach {n v} [my subviews $index] {
		$v local
		dict set uv $n $v
	    }

	    dict set uv "" $index
	    set code [catch {uplevel 1 dict with $vn [list $script]} result eo]

	    switch -- $code {
		1 {# error - re-raise the error
		    return -options $eo $result
		}
		3 {break}
		4 {continue}
		2 {return $result}

		default {# normal
		    lappend results $index $result
		}
	    }
	}

	return $results
    }

    # all - perform script over all records
    method all {script} {
	Debug.view {[self]/$view ([my info]) all over [my size] rows}
	set vn __all__[namespace tail [self]]
	upvar $vn uv
	set results {}
	for {set index [expr {[my size]-1}]} {$index >= 0} {incr index -1} {
	    set uv [my get $index]

	    # create subviews
	    foreach {n v} [my subviews $index] {
		$v local
		dict set uv $n $v
	    }

	    dict set uv "" $index
	    set code [catch {uplevel 1 dict with $vn [list $script]} result eo]

	    switch -- $code {
		1 {# error - re-raise the error
		    return -options $eo $result
		}
		3 {break}
		4 {continue}
		2 {return $result}

		default {# normal
		    lappend results $index $result
		}
	    }
	}
	return $results
    }
 
    # with - perform script over selected records
    method with {script args} {
	if {[llength $args] eq 1} {
	    set args [lindex $args 0]
	}

	set vn __with__[namespace tail [self]]
	upvar $vn uv
	set results {}
	[my select {*}$args] as __vs
	return [uplevel 1 $__vs all [list $script]]

	foreach index [my lselect {*}$args] {
	    set uv [my get $index]
	    dict set uv "" $index
	    foreach {n v} [my subviews $index] {
		$v local
		dict set uv $n $v
	    }
	    switch [catch {
		uplevel 1 dict with $vn [list $script]
	    } result eo] {
		1 {# error - re-raise the error
		    return -options $eo $result
		}
		3 {break}
		4 {continue}
		2 {return $result}

		default {# normal
		    lappend results $index $result
		}
	    }
	}
	return $results
    }

    # set metakit layout from pretty form
    method pretty {layout} {
	Debug.view {pretty '$layout'} 3
	# remove comments
	set r ""
	foreach l [split $layout \n] {
	    set l [string trim [lindex [regexp -inline {[^\#]*} $l] 0]]
	    if {$l ne {}} {
		Debug.view {layout l-ing '$l'} 3
		append r $l " "
	    }
	}

	set pretty ""
	set accum ""
	#set r [string map [list \{\  \{ \ \} \}] $r]
	Debug.view {layout r: $r} 2
	
	foreach el $r {
	    set el [string trim $el]
	    if {$el eq ""} continue
	    set el [string trim $el "\""]
	    lappend accum $el
	    Debug.view {layout accumulating: '$accum'} 3
	    if {![info complete $accum]} {
		continue
	    }

	    if {[llength [lindex $accum 0]] == 1} {
		Debug.view {layout name: '$el' / $accum} 3
		
		lassign [split $accum :] fname t
		set accum ""
		
		if {$t eq ""} {
		    set t ""
		} else {
		    set t ":$t"
		}
		
		lappend pretty ${fname}${t}
	    } else {
		Debug.view {layout subview: '$el' / $accum} 3
		
		# this is a subview declaration
		set fname $accum
		lappend pretty [lindex $accum 0]
		set accum ""
	    }
	}
	
	Debug.view {LAYOUT: '$pretty'}
	return $pretty
    }

    # return the properties of the view
    method properties {} {
	return [$view properties]
    }

    # insert - insert a row after the given index
    method insert {index args} {
	set result [$view insert $index {*}$args]
	Debug.view {[self] insert $index $args -> $result}
	return $result
    }

    # append - append a record to the view
    method append {args} {
	return [my insert end {*}$args]
    }

    # open - open a subview of this record as a new view
    method open {index prop args} {
	Debug.view {[self] open $index $prop $args}
	return [View new [$view open $index $prop] parents [self] {*}$args]
    }

    # search - return index of element containing the property with the given value
    method search {args} {
	Debug.view {[self] search $args}
	return [$view search {*}$args]
    }

    # search - return index of element containing the property with the given value
    method find {args} {
	Debug.view {[self] find $args}
	return [$view find {*}$args]
    }

    # size - return the size of the view
    method size {args} {
	return [$view size {*}$args]
    }

    # blocked - create mapped view which blocks its rows in two levels.
    # This view acts like a large flat view, even though the actual rows are stored in blocks,
    # which are rebalanced automatically to maintain a good trade-off between block size and 
    # number of blocks.
    #
    # The underlying view must be defined with a single view property,
    # with the structure of the subview being as needed.
    method blocked {} {
	return [View new [$view view blocked] parents [self]]
    }

    # clone - construct a new view with the same structure but no data.
    #
    # Structural information can only be maintain for the top level, 
    # subviews will be included but without any properties themselves.
    method clone {} {
	return [View new [$view view clone] parents [self]]
    }

    # copy - construct a new view with a copy of the data.
    method copy {} {
	return [View new [$view view copy] parents [self]]
    }

    # dup - construct a new view with a copy of the data.
    # The copy is a deep copy, because subviews are always copied in full.
    method dup {} {
	return [View new [$view view dup] parents [self]]
    }

    # readonly - create an identity view which only allows reading
    method readonly {} {
	return [View new [$view view readonly] parents [self]]
    }

    # unique - create view with all duplicate rows omitted.
    method unique {} {
	return [View new [$view view unique] parents [self]]
    }

    # flatten - create view with a specific subview expanded, like a join.    
    method flatten {prop} {
	return [View new [$view view flatten $prop] parents [self]]
    }

    # Create view with rows from another view appended.
    #
    # Constructs a view which has all rows of this view, and all rows of the second view appended.
    # The structure of the second view is assumed to be identical to this one.
    # This operation is a bit similar to appending all rows from the second view,
    # but it does not actually store the result anywhere, it just looks like it.
    method concat {view2} {
	return [View new [$view view concat [$view2 view]] parents [list [self] $view2]]
    }

    # different - Create view with all rows not in both views (no dups).
    #
    # Calculates the "XOR" of two sets. This will only work if both input views are sets,
    # i.e. they have no duplicate rows in them.
    method different {view2} {
	return [View new [$view view different [$view2 view]] parents [list [self] $view2]]
    }

    # intersect - Create view with all rows also in the given view (no dups)
    # 
    # Calculates the set intersection. This will only work if both input views are sets,
    # i.e. they have no duplicate rows in them.
    method intersect {view2} {
	return [View new [$view view intersect [$view2 view]] parents [list [self] $view2]]
    }

    # minus - Create view with all rows not in the given view (no dups).
    method minus {view2} {
	return [View new [$view view minus [$view2 view]] parents [list [self] $view2]]
    }

    # map - create mapped view which maintains an index permutation
    #
    # This is an identity view which somewhat resembles the ordered view,
    # it maintains a secondary "map" view to contain the permutation to act as an index.
    # The indexed view presents the same order of rows as the underlying view,
    # but the index map is set up in such a way that binary search is possible
    # on the keys specified. When the "unique" parameter is true, insertions which would
    # create a duplicate key are ignored.
    method map {view2} {
	return [View new [$view view map [$view2 view]] parents [list [self] $view2]]
    }

    # pair - create view which pairs each row with corresponding row.
    method pair {view2} {
	return [View new [$view view pair [$view2 view]] parents [list [self] $view2]]
    }

    # product - create view which is the cartesian product with given view.
    # 
    # The cartesian product is defined as every combination of rows in both views.
    # The number of entries is the product of the number of entries in the two views,
    # properties which are present in both views will use the values defined in this view.
    method product {view2} {
	return [View new [$view view product [$view2 view]] parents [list [self] $view2]]
    }

    # union - create view which is the set union (assumes no duplicate rows).
    method union {view2} {
	return [View new [$view view union [$view2 view]] parents [list [self] $view2]]
    }

    # join - create view which is the relational join on the given keys.
    method join {view2 args} {
	set r [View new [$view view join [$view2 view] {*}$args] parents [list [self] $view2]]
	Debug.view {[self] join $view2 $args -> $r}
	return $r
    }

    # hash - create mapped view which adds a hash lookup layer
    #
    # This view creates and manages a special hash map view, to implement a fast find on the key.
    # The key is defined to consist of the first numKeys_ properties of the underlying view.
    #
    # The map_ view must be empty the first time this hash view is used, so that MetaKit can
    # fill it based on whatever rows are already present in the underlying view.
    # After that, neither the underlying view nor the map view may be modified other
    # than through this hash mapping layer.
    # The defined structure of the map view must be "_H:I,_R:I".
    #
    # This view is modifiable. Insertions and changes to key field properties can cause rows
    # to be repositioned to maintain hash uniqueness.
    # Careful: when a row is changed in such a way that its key is the same as in another row,
    # that other row will be deleted from the view.
    method hash {view2 args} {
	return [View new [$view view hash [$view2 view] {*}$args] parents [list [self] $view2]]
    }

    # indexed - create mapped view which maintains an index permutation
    #
    # This is an identity view which somewhat resembles the ordered view,
    # it maintains a secondary "map" view to contain the permutation to act as an index.
    # The indexed view presents the same order of rows as the underlying view,
    # but the index map is set up in such a way that binary search is possible 
    # on the keys specified.
    # When the "unique" parameter is true, insertions which would create a duplicate key
    # are ignored.
    method indexed {view2 args} {
	return [View new [$view view indexed [$view2 view] {*}$args] parents [list [self] $view2]]
    }

    # groupby - create view with a subview, grouped by the specified properties.
    #
    # This operation is similar to the SQL 'GROUP BY', but it takes advantage 
    # of the fact that MetaKit supports nested views.
    # The view returned from this member has one row per distinct group, with an 
    # extra view property holding the remaining properties.
    # If there are N rows in the original view matching key X, then the result is
    # a row for key X, with a subview of N rows.
    #
    # unfortunately, the subject view must have a subview defined on it for this to work
    # The properties of the subview in the result are all the properties not in the key.
    method groupby {subview args} {
	return [View new [$view view groupby $subview {*}$args] parents [list [self]]]
    }

    # project - create view with the specified property arrangement.
    #
    # The result is virtual, it merely maintains a permutation to access the underlying view.
    # This "derived" view uses change notification to track changes to the underlying view,
    # but this only works when based on views which properly generate change notifications 
    # (.e. raw views, selections, and other projections).
    method project {args} {
	return [View new [$view view project {*}$args] parents [list [self]]]
    }

    # range - create view which is a segment/slice (default is up to end).
    #
    # Returns a view which is a subset, either a contiguous range, or a "slice"
    # with element taken from every step_ entries.
    # If the step is negative, the same entries are returned, but in reverse order
    # (start_ is still lower index, it'll then be returned last).
    method range {args} {
	return [View new [$view view range {*}$args] parents [list [self]]]
    }

    # rename - create view with one property renamed (must be of same type).
    method rename {args} {
	return [View new [$view view rename {*}$args] parents [list [self]]]
    }

    # restrict the search range for rows.
    method restrict {args} {
	return [View new [$view view rename {*}$args] parents [list [self]]]
    }

    # ordered - create mapped view which keeps its rows ordered.
    # 
    # This is an identity view, which has as only use to inform MetaKit that the underlying
    # view can be considered to be sorted on its first numKeys_ properties.
    # The effect is that c4_View::Find will try to use binary search when the search
    # includes key properties
    # (results will be identical to unordered views, the find will just be more efficient).
    #
    # This view is modifiable. Insertions and changes to key field properties can cause rows
    # to be repositioned to maintain the sort order. Careful: when a row is changed in such 
    # a way that its key is the same as in another row, that other row will be deleted from 
    # the view.
    method ordered {args} {
	return [View new [$view view ordered {*}$args] parents [list [self]]]
    }

    # return field names within view
    method names {} {
	set result {}
	foreach f [split [$view properties]] {
	    lappend result [split $f :]
	}
	return $result
    }

    # all views in this db
    method views {} {return [::mk::file views $db]}

    # the name of this View
    method name {} {return $name}

    # the underlying view
    method view {} {return $view}

    # our first parent
    method parent {} {return [lindex $parents 0]}

    # delete the indicated rows
    method delete {args} {
	return [$view delete {*}$args]
    }
    
    method exists {args} {
	return [$view exists {*}$args]
    }

    # close this view
    method close {} {
	[self] destroy
    }

    method clear {} {
	[self] size 0
    }

    ###################
    # db level commands
    
    # return the view's db
    method db {args} {
	if {![llength $args]} {
	    return $db
	} else {
	    return [::mk::file {*}$args $db]
	}
    }

    method child {args} {
	if {[llength $args] == 1} {
	    set args [lindex $args 0]
	}
	if {![llength $args]} {
	    return [dict keys $children]
	}
	set args [lassign $args cmd]
	switch -- $cmd {
	    add {
		dict set children [lindex $args 0] {}
	    }
	    rm {
		catch {dict unset children [lindex $args 0]}
	    }
	}
    }

    variable db view name parents children type logger

    # construct or open a view
    constructor {args} {
	set mixins {}
	set children {}
	set parents {}
	if {[llength $args]%2} {
	    # we're wrapping an existing view
	    # (could be from one of the mk view builtins.)
	    set args [lassign $args view]
	    catch {dict unset args view}
	    Debug.view {View [self] synthetic constructor over $view ([$view info]): $args}
	    foreach {n v} $args {
		set $n $v
	    }
	    if {[info exists parents] && $parents ne ""} {
		set db [[lindex $parents 0] db]	;# our db is our parents' db
	    }
	    if {[dict exists $args type] && [dict get $args type] eq "index"} {
		lappend mixins ViewSyn
	    }
	} else {
	    Debug.view {View constructor: $args}
	    # no already-open view supplied, have to open it
	    foreach {n v} $args {
		set $n $v
	    }

	    # if the caller hasn't provided a name, use object name.
	    # interpret a composite name as meaning db.viewname
	    # if the name isn't composite, then we require
	    # db to be explicitly supplied
	    if {![info exists name]} {
		set name [namespace tail [self]]	;# use the object name
	    }
	    set name [lindex [lassign [split $name .] dbi] 0]
	    if {$name eq {}} {
		set name $dbi
	    } else {
		set db $dbi
	    }
	    
	    # open the database if it's not already open
	    if {![dict exists [mk::file open] $db]} {
		if {[info exists file]} {
		    set flags {}
		    foreach flag {-readonly -nocommit -extend -shared} {
			if {[dict exists $args $flag] && [dict get $args $flag]} {
			    lappend flags $flag
			}
		    }
		    ::mk::file open $db $file {*}$flags
		} else {
		    error "Must specify either an open db, or a file and db name"
		}
	    }
	    
	    # layout the view if it's not already in the db
	    # this will require a layout or an ini file.
	    if {$name ni [::mk::file views $db]} {
		# this is a new view within $db
		if {[info exists ini]} {
		    package require inifile
		    set fd [::ini::open $ini]
		    if {[::ini::exists $fd $name]} {
			foreach key [::ini::keys $fd $name] {
			    set v [::ini::value $fd $name $key]
			    lappend layout $key:$v
			}
		    }
		    ::ini::close $fd
		}
		
		if {[info exists layout]} {
		    Debug.view {layout $db.$name [my pretty $layout]}
		    ::mk::view layout $db.$name [my pretty $layout]
		} else {
		    error "Must specify a pre-existing view, or view and layout or view and ini"
		}
	    } else {
		# got a view in the db
	    }
	    
	    # create the metakit view command which we're wrapping
	    set view [::mk::view open $db.$name]
	}

	if {[info exists logger] && $logger ne ""} {
	    lappend mixins ViewLogger
	}

	if {[llength $mixins]} {
	    oo::objdefine [self] mixin {*}$mixins
	}

	if {[info exists logger] && $logger ne ""} {
	    my logger $logger	;# initialize the logging functional
	}

	foreach p $parents {
	    $p child add [self]
	}
    }

    destructor {
	Debug.view {destroy [self]}
	foreach p $parents {
	    $p child rm [self]
	}
	$view close
    }
}

if {[info exists argv0] && ($argv0 eq [info script])} {
    package require Mk4tcl

    View create sdb.v file sdb.mk layout {time:I value date}
    #View create sdb.v file sdb.mk ini sdb.ini
    foreach v {foot head neck dangly_bits} {
	sdb.v append time [clock seconds] value $v
    }
    sdb.v db commit

    puts stderr "size: [sdb.v size]"
    puts stderr "select:[sdb.v lselect value head]"

    sdb.v update {value foot} {
	set date [clock format $time]
    } date time

    puts stderr "0: [sdb.v get 0]"
    puts stderr [sdb.v with {
	set result "time:$time value:$value date:$date"
    } -min date "!"]
    puts stderr [sdb.v subst {value:$value time:$time} date ""]
    sdb.v close
}
