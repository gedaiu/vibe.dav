/**
 * Authors: Szabo Bogdan <szabobogdan@yahoo.com>
 * Date: 3 9, 2015
 * License: Subject to the terms of the MIT license, as written in the included LICENSE.txt file.
 * Copyright: Public Domain
 */
module vibedav.ifheader;

import tested;

import vibedav.parser;

import std.stdio;
import std.string;
import core.vararg;

struct IfCondition {

	string condition;
	string etag;
	bool isNot;

	this(string condition) {
		parse(condition);
	}

	private void parse(string data) {
		void addConditionCallback(string value) {
			condition = value[1..$-1];
		}

		void notConditionCallback(string value) {
			isNot = true;
		}

		void etagConditionCallback(string value) {
			writeln("");
			etag = value[2..$-2];
		}

		Parser parser;

		ParseInsideToken valueToken = new ParseInsideToken;
		valueToken.startChar = '<';
		valueToken.endChar = '>';
		valueToken.callback = &addConditionCallback;

		ParseInsideToken etagToken = new ParseInsideToken;
		etagToken.startChar = '[';
		etagToken.endChar = ']';
		etagToken.callback = &etagConditionCallback;

		ParseStaticToken notToken = new ParseStaticToken;
		notToken.value = "Not";
		notToken.callback = &notConditionCallback;

		parser.tokens ~= valueToken;
		parser.tokens ~= notToken;
		parser.tokens ~= etagToken;
		parser.start(data);
	}
}

struct IfHeader {

	IfCondition list[string][];

	@property {
		bool isEmpty() {
			return list.keys.length == 0;
		}
	}

	string getAttr(string href, ...) {
		string[] hrefList = [href];

		//get the list of hrefs
		for (int i = 0; i < _arguments.length; i++) {
			if (_arguments[i] == typeid(string))
				hrefList ~= va_arg!(string)(_argptr);
			else
				throw new Exception("Invalid variadic type. string expected.");
		}

		//find the first attribute
		foreach(attr; hrefList)
			if(attr in list && list[attr].length > 0)
				return list[attr][0].condition;

		return "";
	}

	bool has(string path, string condition) {
		if(path in list)
			foreach(IfCondition ifCondition; list[path]) {
				if(ifCondition.condition == condition && !ifCondition.isNot)
					return true;
			}

		return false;
	}

	bool hasNot(string path, string condition) {
		if(path in list)
			foreach(ifCondition; list[path])
				if(ifCondition.condition == condition && ifCondition.isNot)
					return true;

		return false;
	}

	bool[string] getLocks(string url) {
		bool[string] result;

		if("" in list) {
			foreach(IfCondition ifCondition; list[""])
				if(!ifCondition.isNot)
					result[ifCondition.condition] = true;
		}

		foreach(u, urlList; list) {
			if(url.indexOf(u) != -1)
				foreach(IfCondition ifCondition; list[u])
					if(!ifCondition.isNot)
						result[ifCondition.condition] = true;
		}

		return result;
	}

	static IfHeader parse(string data) {
		IfHeader ifHeader;
		string path = "";

		void conditionTokenCallback(string data) {
			string condition = data[1..$-1];

			if(path !in ifHeader.list)
				ifHeader.list[path] = [ IfCondition(condition) ];
			else
				ifHeader.list[path] ~= IfCondition(condition);
		}

		void pathTokenCallback(string data) {
			path = data[1..$-1];
		}

		Parser parser;

		ParseInsideToken conditionToken = new ParseInsideToken;
		conditionToken.startChar = '(';
		conditionToken.endChar = ')';
		conditionToken.callback = &conditionTokenCallback;

		ParseInsideToken pathToken = new ParseInsideToken;
		pathToken.startChar = '<';
		pathToken.endChar = '>';
		pathToken.callback = &pathTokenCallback;

		parser.tokens ~= conditionToken;
		parser.tokens ~= pathToken;

		if(data != "" && data != "()")
			parser.start(data);

		return ifHeader;
	}
}

@name("No-Tag-List")
unittest {
	auto tag = IfHeader.parse("(<urn:uuid:150852e2-3847-42d5-8cbe-0f4f296f26cf>)");

	assert(tag.list.keys.length == 1);
	assert(tag.has("", "urn:uuid:150852e2-3847-42d5-8cbe-0f4f296f26cf"));
}

@name("Tagged-List")
unittest {
	auto tag = IfHeader.parse("<http://example.com/locked/> (<urn:uuid:150852e2-3847-42d5-8cbe-0f4f296f26cf>) (<other>)");

	assert(tag.list.keys.length == 1);
	assert(tag.has("http://example.com/locked/", "urn:uuid:150852e2-3847-42d5-8cbe-0f4f296f26cf"));
	assert(tag.has("http://example.com/locked/", "other"));
}

@name("Tagged-List")
unittest {
	auto tag = IfHeader.parse("<http://example.com/locked/> (<urn:uuid:150852e2-3847-42d5-8cbe-0f4f296f26cf>)");

	assert(tag.list.keys.length == 1);
	assert(tag.has("http://example.com/locked/", "urn:uuid:150852e2-3847-42d5-8cbe-0f4f296f26cf"));
}

@name("multiple conditions")
unittest {
	auto tag = IfHeader.parse("(<urn:uuid:181d4fae-7d8c-11d0-a765-00a0c91e6bf2>) (Not <DAV:no-lock>)");

	assert(tag.list.keys.length == 1);
	assert(tag.has("", "urn:uuid:181d4fae-7d8c-11d0-a765-00a0c91e6bf2"));
	assert(!tag.has("", "DAV:no-lock"));
	assert(tag.hasNot("", "DAV:no-lock"));
	assert(!tag.hasNot("", "urn:uuid:181d4fae-7d8c-11d0-a765-00a0c91e6bf2"));
}

@name("etag conditions")
unittest {
	auto tag = IfHeader.parse(`(<DAV:no-lock> ["C8E30A4F4684AB4A5053F6C1ACBA1023"])`);

	assert(tag.list.keys.length == 1);
	assert(tag.has("", "DAV:no-lock"));
	assert(tag.list[""][0].etag == "C8E30A4F4684AB4A5053F6C1ACBA1023");
}
