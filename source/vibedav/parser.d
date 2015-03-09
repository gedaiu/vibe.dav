/**
 * Authors: Szabo Bogdan <szabobogdan@yahoo.com>
 * Date: 3 9, 2015
 * License: Subject to the terms of the MIT license, as written in the included LICENSE.txt file.
 * Copyright: Public Domain
 */
module vibedav.parser;

struct Parser {
	ParseToken[] tokens;

	void start(string data) {
		foreach(i; 0..data.length) {
			bool isInside;

			foreach(token; tokens)
				if(token.isInside)
					isInside = true;

			if(!isInside) {
				foreach(token; tokens) {
					if(token.checkStart(data, i)) {
						token.isInside = true;
						token.start = i;
					}
				}
			} else {
				foreach(token; tokens) {
					if(token.isInside && token.checkEnd(data, i)) {
						token.isInside = false;

						if(token.callback !is null)
							token.callback(data[token.start..i+1]);
					}
				}
			}
		}
	}
}

abstract class ParseToken {
	alias ParseCallback = void delegate(string data);

	bool isInside;
	ulong start;

	bool checkStart(string data, ulong pos);
	bool checkEnd(string data, ulong pos);

	ParseCallback callback;
}


class ParseInsideToken : ParseToken {
	char startChar;
	char endChar;

	override bool checkStart(string data, ulong pos) {
		return data[pos] == startChar;
	}
	override bool checkEnd(string data, ulong pos) {
		return data[pos] == endChar;
	}
}

class ParseStaticToken : ParseToken {
	alias ParseCallback = void delegate(string data);

	bool isInside;
	ulong start;
	string value;

	override bool checkStart(string data, ulong pos) {
		if(data.length - pos < value.length)
			return false;

		return data[pos..pos+value.length] == value;
	}
	override bool checkEnd(string data, ulong pos) {
		if(pos < value.length)
			return false;

		return data[pos-value.length..pos] == value;
	}
}
