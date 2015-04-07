/**
 * Authors: Szabo Bogdan <szabobogdan@yahoo.com>
 * Date: 2 18, 2015
 * License: Subject to the	 terms of the MIT license, as written in the included LICENSE.txt file.
 * Copyright: Public Domain
 */
module vibedav.icalendar;

import tested;

private mixin template vAccessTpl() {
	private {
		string[string] uniqueValues;
		string[][string] optionalValues;

		bool setUnique(string value, string key) {
			foreach(k; OptionalUnique) {
				if(key == k) {
					if(k in uniqueValues)
						throw new Exception("Key is `"~key~"` already set.");

					uniqueValues[key] = value;
					return true;
				}
			}

			return false;
		}

		bool setOptional(string value, string key) {
			foreach(k; Optional) {
				if(key == k) {
					optionalValues[key] ~= value;
					return true;
				}
			}

			return false;
		}

		string asString(string type)() {
			string a;

			foreach(key, value; uniqueValues)
				a ~= key ~ ":" ~ value ~ "\n";

			foreach(key, valueList; optionalValues)
				foreach(value; valueList)
					a ~= key ~ ":" ~ value ~ "\n";

			return "BEGIN:"~type~"\n" ~ a ~ "END:" ~ type;
		}
	}

    void opIndexAssign(string value, string key) {
    	if(!setUnique(value, key) && !setOptional(value, key))
    		throw new Exception("Invalid key `"~key~"`");
    }

    string opIndex(string key) {
    	return uniqueValues[key];
    }

    void remove(string key) {
    	optionalValues.remove(key);
    }
}

struct vEvent {
	/// the following are optional,
    /// but MUST NOT occur more than once
    enum OptionalUnique = [
    	"CLASS",
    	"CREATED",
    	"DESCRIPTION",
    	"DTSTART",
    	"GEO",
    	"LAST-MOD",
    	"LOCATION",
    	"ORGANIZER",
    	"PRIORITY",
    	"DTSTAMP",
    	"SEQ",
    	"STATUS",
    	"SUMMARY",
    	"TRANSP",
    	"UID",
    	"URL",
    	"RECURID"
    ];

    //either 'dtend' or 'duration' may appear in
    //a 'eventprop', but 'dtend' and 'duration'
    //MUST NOT occur in the same 'eventprop'
	enum OptionalOr = [ "DTEND", "DURATION" ];

     /// the following are optional,
    /// and MAY occur more than once
    enum Optional = [
    	"ATTACH",
    	"ATTENDEE",
    	"CATEGORIES",
    	"COMMENT",
    	"CONTACT",
    	"EXDATE",
    	"EXRULE",
    	"RSTATUS",
    	"RELATED",
    	"RESOURCES",
    	"RDATE",
    	"RRULE"
    ];

    mixin vAccessTpl;

    string toString() {
    	return asString!"VEVENT";
    }
}

@name("Set unique property")
unittest {
	vEvent event;

	event["CLASS"] = "value";

	assert(event.toString == "BEGIN:VEVENT\nCLASS:value\nEND:VEVENT");
}

@name("Set unique property twice throw Exception")
unittest {
	vEvent event;

	bool failed;

	event["CLASS"] = "value1";
	try {
		event["CLASS"] = "value2";
	} catch(Exception e) {
		failed = true;
	}

	assert(failed);
	assert(event.toString == "BEGIN:VEVENT\nCLASS:value1\nEND:VEVENT");
}

@name("Set optional properties")
unittest {
	vEvent event;

	event["ATTACH"] = "value1";
	event["ATTACH"] = "value2";
	assert(event.toString == "BEGIN:VEVENT\nATTACH:value1\nATTACH:value2\nEND:VEVENT");
}

struct vTodo {
	/// the following are optional,
    /// but MUST NOT occur more than once
    enum OptionalUnique = [
	    "CLASS",
	    "COMPLETED",
	    "CREATED",
	    "DESCRIPTION",
	    "DTSTAMP",
	    "DTSTART",
	    "GEO",
	    "LAST-MOD",
	    "LOCATION",
	    "ORGANIZER",
	    "PERCENT",
	    "PRIORITY",
	    "RECURID",
	    "SEQ",
	    "STATUS",
	    "SUMMARY",
	    "UID",
	    "URL"
	];

	/// either 'due' or 'duration' may appear in
	/// a 'todoprop', but 'due' and 'duration'
	/// MUST NOT occur in the same 'todoprop'
	enum OptionalOr = [ "DUE", "DURATION" ];

    /// the following are optional,
    /// and MAY occur more than once
    enum Optional = [
	    "ATTACH",
	    "ATTENDEE",
	    "CATEGORIES",
	    "COMMENT",
	    "CONTACT",
	    "EXDATE",
	    "EXRULE",
	    "RSTATUS",
	    "RELATED",
	    "RESOURCES",
	    "RDATE",
	    "RRULE"
	];

    mixin vAccessTpl;

    string toString() {
    	return asString!"VTODO";
    }
}

/// Provide a grouping of component properties that describe a
/// journal entry.
struct vJournal {

	/// the following are optional,
    /// but MUST NOT occur more than once
    enum OptionalUnique = [
    	"CLASS",
    	"CREATED",
    	"DESCRIPTION",
    	"DTSTART",
    	"DTSTAMP",
    	"LAST-MOD",
    	"ORGANIZER",
    	"RECURID",
    	"SEQ",
    	"STATUS",
    	"SUMMARY",
    	"UID",
    	"URL"
    ];

    enum OptionalOr= [];

    /// the following are optional,
    /// and MAY occur more than once
    enum Optional = [
	    "ATTACH",
	    "ATTENDEE",
	    "CATEGORIES",
	    "COMMENT",
	    "CONTACT",
	    "EXDATE",
	    "EXRULE",
	    "RELATED",
	    "RDATE"
	    "RRULE",
	    "RSTATUS"
    ];

    mixin vAccessTpl;

     string toString() {
    	return asString!"VJOURNAL";
    }
}

struct vFreeBussy {
	/// the following are optional,
    /// but MUST NOT occur more than once
    enum OptionalUnique = [
	    "CONTACT",
	    "DTSTART",
	    "DTEND",
	    "DURATION",
	    "DTSTAMP",
	    "ORGANIZER",
	    "UID",
	    "URL"
	];

	enum OptionalOr = [];

     /// the following are optional,
    /// and MAY occur more than once
    enum Optional = [
	    "ATTENDEE",
	    "COMMENT",
	    "FREEBUSY",
	    "RSTATUS"
	];

    mixin vAccessTpl;

	string toString() {
		return asString!"VFREEBUSSY";
    }
}

struct vTimezone {

	/// 'tzid' is required, but MUST NOT occur more
	/// than once
	enum Required = [ "TZID" ];

	enum string[] Optional = [];

	/// 'last-mod' and 'tzurl' are optional,
	/// but MUST NOT occur more than once
	enum OptionalUnique = [
	    "LAST-MOD",
	    "TZURL"
	];

	/// one of 'standardc' or 'daylightc' MUST occur
	/// and each MAY occur more than once.
	enum OptionalOr = [ "STANDARDC", "DAYLIGHTC" ];

    mixin vAccessTpl;

	string toString() {
    	return asString!"VTIMEZONE";
    }
}

struct vAlarm {

	enum string[] OptionalUnique = [];

	enum Optional = [
		"action",
		"attach",
		"description",
		"trigger",
		"summary",
		"attendee",
		"duration",
		"repeat",
		"attach"];


    mixin vAccessTpl;

	string toString() {
    	return asString!"VALARM";
    }
}

struct iCalendar {
	vEvent[] vEvents;
	vTodo[] vTodos;
	vJournal[] vJournals;
	vFreeBussy[] vFreeBussys;
	vTimezone[] vTimezones;
	vAlarm[] vAlarms;
}
