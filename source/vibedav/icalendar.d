/**
 * Authors: Szabo Bogdan <szabobogdan@yahoo.com>
 * Date: 2 18, 2015
 * License: Subject to the	 terms of the MIT license, as written in the included LICENSE.txt file.
 * Copyright: Public Domain
 */
module vibedav.icalendar;

import std.string;
import std.stdio;

private mixin template vAccessTpl()
{
	private
	{
		string[string] uniqueValues;
		string[][string] optionalValues;

		bool setUnique(string value, string key)
		{
			foreach (k; OptionalUnique)
			{
				if (key == k)
				{
					if (k in uniqueValues)
						throw new Exception("Key is `" ~ key ~ "` already set.");

					uniqueValues[key] = value;
					return true;
				}
			}

			return false;
		}

		bool setOptional(string value, string key)
		{
			foreach (k; Optional)
			{
				if (key == k)
				{
					optionalValues[key] ~= value;
					return true;
				}
			}

			if (key.length > 2 && key[0 .. 2] == "X-")
				return true;

			return false;
		}

		bool setOptionalOr(string value, string key)
		{
			bool exists;

			foreach (k; OptionalOr)
			{
				if (k in uniqueValues)
					return false;

				if (k == key)
					exists = true;
			}

			if (!exists)
				return false;

			uniqueValues[key] = value;

			return true;
		}

		string asString(string type)()
		{
			string a;

			foreach (key, value; uniqueValues)
				a ~= key ~ ":" ~ value ~ "\n";

			foreach (key, valueList; optionalValues)
				foreach (value; valueList)
					a ~= key ~ ":" ~ value ~ "\n";

			return "BEGIN:" ~ type ~ "\n" ~ a ~ "END:" ~ type;
		}
	}

	void opIndexAssign(string value, string key)
	{
		if (!setUnique(value, key) && !setOptional(value, key) && !setOptionalOr(value, key))
			throw new Exception("Invalid key `" ~ key ~ "`");
	}

	string opIndex(string key)
	{
		return uniqueValues[key];
	}

	void remove(string key)
	{
		optionalValues.remove(key);
	}
}

struct vEvent
{
	/// the following are optional,
	/// but MUST NOT occur more than once
	enum OptionalUnique = [
			"CLASS", "CREATED", "DESCRIPTION", "DTSTART", "GEO", "LAST-MOD", "LOCATION", "ORGANIZER",
			"PRIORITY", "DTSTAMP", "SEQ", "STATUS", "SUMMARY", "TRANSP", "UID",
			"URL", "RECURID", "SEQUENCE"
		];

	//either 'dtend' or 'duration' may appear in
	//a 'eventprop', but 'dtend' and 'duration'
	//MUST NOT occur in the same 'eventprop'
	enum string[] OptionalOr = ["DTEND", "DURATION"];

	/// the following are optional,
	/// and MAY occur more than once
	enum Optional = [
			"ATTACH", "ATTENDEE", "CATEGORIES", "COMMENT", "CONTACT", "EXDATE",
			"EXRULE", "RSTATUS", "RELATED", "RESOURCES", "RDATE", "RRULE"
		];

	mixin vAccessTpl;

	string toString()
	{
		return asString!"VEVENT";
	}
}

@("Set unique property")
unittest
{
	vEvent event;

	event["CLASS"] = "value";

	assert(event.toString == "BEGIN:VEVENT\nCLASS:value\nEND:VEVENT");
}

@("Set unique property twice throw Exception")
unittest
{
	vEvent event;

	bool failed;

	event["CLASS"] = "value1";
	try
	{
		event["CLASS"] = "value2";
	}
	catch (Exception e)
	{
		failed = true;
	}

	assert(failed);
	assert(event.toString == "BEGIN:VEVENT\nCLASS:value1\nEND:VEVENT");
}

@("Set optional properties")
unittest
{
	vEvent event;

	event["ATTACH"] = "value1";
	event["ATTACH"] = "value2";
	assert(event.toString == "BEGIN:VEVENT\nATTACH:value1\nATTACH:value2\nEND:VEVENT");
}

struct vTodo
{
	/// the following are optional,
	/// but MUST NOT occur more than once
	enum OptionalUnique = [
			"CLASS", "COMPLETED", "CREATED", "DESCRIPTION", "DTSTAMP", "DTSTART", "GEO", "LAST-MOD", "LOCATION",
			"ORGANIZER", "PERCENT", "PRIORITY", "RECURID", "SEQ", "STATUS",
			"SUMMARY", "UID", "URL"
		];

	/// either 'due' or 'duration' may appear in
	/// a 'todoprop', but 'due' and 'duration'
	/// MUST NOT occur in the same 'todoprop'
	enum string[] OptionalOr = ["DUE", "DURATION"];

	/// the following are optional,
	/// and MAY occur more than once
	enum Optional = [
			"ATTACH", "ATTENDEE", "CATEGORIES", "COMMENT", "CONTACT", "EXDATE",
			"EXRULE", "RSTATUS", "RELATED", "RESOURCES", "RDATE", "RRULE"
		];

	mixin vAccessTpl;

	string toString()
	{
		return asString!"VTODO";
	}
}

/// Provide a grouping of component properties that describe a
/// journal entry.
struct vJournal
{

	/// the following are optional,
	/// but MUST NOT occur more than once
	enum OptionalUnique = [
			"CLASS", "CREATED", "DESCRIPTION", "DTSTART", "DTSTAMP", "LAST-MOD",
			"ORGANIZER", "RECURID", "SEQ", "STATUS", "SUMMARY", "UID", "URL"
		];

	enum string[] OptionalOr = [];

	/// the following are optional,
	/// and MAY occur more than once
	enum Optional = [
			"ATTACH", "ATTENDEE", "CATEGORIES", "COMMENT", "CONTACT", "EXDATE",
			"EXRULE", "RELATED", "RDATE" "RRULE", "RSTATUS"
		];

	mixin vAccessTpl;

	string toString()
	{
		return asString!"VJOURNAL";
	}
}

struct vFreeBussy
{
	/// the following are optional,
	/// but MUST NOT occur more than once
	enum OptionalUnique = [
			"CONTACT", "DTSTART", "DTEND", "DURATION", "DTSTAMP", "ORGANIZER", "UID", "URL"
		];

	enum string[] OptionalOr = [];

	/// the following are optional,
	/// and MAY occur more than once
	enum Optional = ["ATTENDEE", "COMMENT", "FREEBUSY", "RSTATUS"];

	mixin vAccessTpl;

	string toString()
	{
		return asString!"VFREEBUSSY";
	}
}

struct vTimezone
{

	/// 'tzid' is required, but MUST NOT occur more
	/// than once
	enum Required = ["TZID"];

	enum string[] Optional = [];

	/// 'last-mod' and 'tzurl' are optional,
	/// but MUST NOT occur more than once
	enum OptionalUnique = ["LAST-MOD", "TZURL"];

	/// one of 'standardc' or 'daylightc' MUST occur
	/// and each MAY occur more than once.
	enum string[] OptionalOr = ["STANDARDC", "DAYLIGHTC"];

	mixin vAccessTpl;

	string toString()
	{
		return asString!"VTIMEZONE";
	}
}

struct vAlarm
{

	enum string[] OptionalUnique = [];

	enum string[] OptionalOr = [];

	enum Optional = [
			"action", "attach", "description", "trigger", "summary",
			"attendee", "duration", "repeat", "attach"
		];

	mixin vAccessTpl;

	string toString()
	{
		return asString!"VALARM";
	}
}

struct iCalendar
{
	vEvent[] vEvents;
	vTodo[] vTodos;
	vJournal[] vJournals;
	vFreeBussy[] vFreeBussys;
	vTimezone[] vTimezones;
	vAlarm[] vAlarms;
}

vEvent parseVEvent(string[] data)
{
	vEvent ev;

	foreach (item; data)
	{
		auto valueSep = item.indexOf(":");
		auto metaSep = item.indexOf(";");
		string key;
		string val;

		if (metaSep != -1 && metaSep < valueSep)
		{
			key = item[0 .. metaSep];
			val = item[metaSep + 1 .. $];
		}
		else
		{
			auto row = item.split(":");

			assert(row.length == 2);

			key = row[0];
			val = row[1];
		}

		ev[key] = val;
	}

	return ev;
}

iCalendar parseICalendar(string data)
{
	iCalendar calendar;

	auto rows = data.split("\n");

	string[] tmpData;
	bool found;

	foreach (row; rows)
	{
		row = row.strip;

		if (row == "BEGIN:VEVENT")
			found = true;
		else if (row == "END:VEVENT")
		{
			found = false;
			calendar.vEvents ~= parseVEvent(tmpData);
			tmpData = [];
		}
		else if (found)
			tmpData ~= row;
	}

	return calendar;
}

@("Parse VEVENT")
unittest
{

	string data = "BEGIN:VCALENDAR
VERSION:2.0
PRODID:-//Apple Inc.//Mac OS X 10.10.3//EN
CALSCALE:GREGORIAN
BEGIN:VEVENT
CREATED:20150412T100602Z
UID:675FC7E1-B891-4C58-9B60-000000000000
DTEND:20150401T010000Z
TRANSP:OPAQUE
SUMMARY:some name2
DTSTART:20150401T000000Z
DTSTAMP:20150412T100602Z
SEQUENCE:0
END:VEVENT
END:VCALENDAR";

	auto parsed = data.parseICalendar;

	assert(parsed.vEvents.length == 1);
	assert(parsed.vEvents[0]["DTSTART"] == "20150401T000000Z");
}

@("Parse VEVENT with timezone")
unittest
{

	string data = "BEGIN:VCALENDAR
VERSION:2.0
PRODID:-//Apple Inc.//Mac OS X 10.10.3//EN
CALSCALE:GREGORIAN
BEGIN:VEVENT
DTEND;TZID=Europe/Bucharest:20150401T010000Z
END:VEVENT
END:VCALENDAR";

	auto parsed = data.parseICalendar;

	assert(parsed.vEvents.length == 1);
	assert(parsed.vEvents[0]["DTEND"] == "TZID=Europe/Bucharest:20150401T010000Z");
}
