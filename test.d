import std.typetuple;

import vibedav.base;
import vibedav.filedav;
import vibedav.caldav;
import vibedav.prop;
import vibedav.ifheader;
import vibedav.parser;
import vibedav.icalendar;

import dub_test_root;

import std.stdio;
import core.runtime;

shared bool result;

int main() {

	if(!result) {
		return 1;
	}

	writeln("All unit tests have been run successfully.");

	return 0;
}
shared static this() {
	version (Have_tested) {
		import tested;
		import core.runtime;
		import std.exception;
		Runtime.moduleUnitTester = () => true;

		//runUnitTests!app(new JsonTestResultWriter("results.json"));

		//result = runUnitTests!allModules(new ConsoleTestResultWriter);
		result = runUnitTests!allModules(new JsonDetailTestResultWriter("results.json"));
	}
}

