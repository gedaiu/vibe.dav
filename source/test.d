import std.typetuple;

import vibedav.base;
import vibedav.file;
import vibedav.prop;
import vibedav.util;
import vibedav.ifheader;
import vibedav.parser;
alias allModules = TypeTuple!(vibedav.base,
							  vibedav.file,
							  vibedav.prop,
							  vibedav.util,
							  vibedav.ifheader,
							  vibedav.parser);

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

		//enforce(runUnitTests!allModules(new ConsoleTestResultWriter), "Unit tests failed.");
		result = runUnitTests!allModules(new JsonTestResultWriter("results.json"));
	}
}

