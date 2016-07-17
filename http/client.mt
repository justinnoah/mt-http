import "lib/codec/utf8" =~  [=> UTF8 :DeepFrozen]
import "lib/gai" =~ [=> makeGAI :DeepFrozen]
import "lib/enum" =~ [=> makeEnum :DeepFrozen]
import "lib/tubes" =~ [
    => makePureDrain :DeepFrozen,
    => makeFount :DeepFrozen,
]
import "http/headers" =~ [
    => Headers :DeepFrozen,
    => emptyHeaders :DeepFrozen,
    => parseHeader :DeepFrozen,
]
exports (main, makeRequest)

# Copyright (C) 2014 Google Inc. All rights reserved.
#
# Licensed under the Apache License, Version 2.0 (the "License"); you may not
# use this file except in compliance with the License. You may obtain a copy
# of the License at
#
# http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS, WITHOUT
# WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied. See the
# License for the specific language governing permissions and limitations
# under the License.


def lowercase(specimen, ej) as DeepFrozen:
    def s :Str exit ej := specimen
    return s.toLowerCase()

def finiteBody(headers :Headers) :Bool as DeepFrozen:
    return headers.getContentLength() != null

def smallBody(headers :Headers) :Bool as DeepFrozen:
    def contentLength := headers.getContentLength()
    return contentLength != null && contentLength < 1024 * 1024


def makeResponse(status :Int, headers :Headers, bodyFount) as DeepFrozen:
    return object response extends bodyFount:
        to _printOn(out):
            out.print(`<response $status: $headers>`)

        to status() :Int:
            return status

        to headers() :Headers:
            return headers


def [HTTPState :DeepFrozen,
     REQUEST :DeepFrozen,
     HEADER :DeepFrozen,
     BODY :DeepFrozen,
] := makeEnum(["request", "header", "body"])


def makeBodyController(headers :Headers) as DeepFrozen:
    def contentLength :NullOk[Int] := headers.getContentLength()
    var resolver := null
    var buf :Bytes := b``
    var done :Bool := false

    def run() :Vow:
        traceln(`run() $done ${buf.size()} $resolver`)
        if (done):
            return if (buf.size() == 0):
                makeFount.sentinel()
            else:
                # Final chunk.
                def rv := buf
                buf := b``
                return rv
        else:
            def [p, r] := Ref.promise()
            resolver := r
            return p

    def feed(bs :Bytes) :Bool:
        traceln(`feed($bs)`)
        buf += bs
        if (resolver != null):
            resolver.resolve(buf)
            buf := b``
        return true

    return if (contentLength == null):
        object streamingBodyController:
            "A controller for a streaming body."

            to run() :Vow:
                return run()

            to feed(bs :Bytes) :Bool:
                return feed(bs)
    else:
        var remaining :Int := contentLength

        object finiteBodyController:
            "A controller for a finite body."

            to run() :Vow:
                return run()

            to feed(bs :Bytes) :Bool:
                remaining -= bs.size()
                if (remaining <= 0):
                    feed(bs)
                    done := true
                    return false
                else:
                    return feed(bs)


def makeResponseDrain(resolver) as DeepFrozen:
    var state :HTTPState := REQUEST
    var buf :Bytes := b``
    var headers :Headers := emptyHeaders()
    var status :NullOk[Int] := null

    var bodyController := null
    var bodyMachine := null

    def nextLine(ej) :Bytes:
        def b`@line$\r$\n@tail` exit ej := buf
        buf := tail
        return line

    return object responseDrain:
        to receive(bytes):
            buf += bytes
            responseDrain.parse()

        to flowingFrom(fount):
            return responseDrain

        to flowAborted(reason):
            traceln(`Flow aborted: $reason`)

        to flowStopped(reason):
            traceln(`End of response: $reason`)

        to parseStatus(ej):
            def line := nextLine(ej)
            if (line =~ b`HTTP/1.1 @{via (_makeInt.fromBytes) s} @label`):
                status := s
                traceln(`Status: $status ($label)`)
                state := HEADER
                headers := emptyHeaders()

        to parseHeader(ej):
            def line := nextLine(ej)
            if (line.size() == 0):
                # Double newline; end of headers.
                state := BODY
                bodyController := makeBodyController(headers)
                def fount := makeFount.fromController(bodyController)
                def response := makeResponse(status, headers, fount)
                resolver.resolve(response)
            else:
                headers := parseHeader(headers, line)

        to parse():
            while (true):
                switch (state):
                    match ==REQUEST:
                        responseDrain.parseStatus(__break)
                    match ==HEADER:
                        responseDrain.parseHeader(__break)
                    match ==BODY:
                        def more := bodyController.feed(buf)
                        buf := b``
                        if (!more):
                            bodyController := null
                            state := REQUEST
                        break


def makeRequest(makeTCP4ClientEndpoint, host :Bytes, resource :Str,
                => port :Int := 80) as DeepFrozen:
    def headers := [
        "Host" => host,
        "Connection" => b`close`,
    ].diverge()

    return object request:
        to put(key, value :Bytes):
            headers[key] := value

        to write(verb, drain):
            drain.receive(UTF8.encode(`$verb $resource HTTP/1.1$\r$\n`, null))
            for via (UTF8.encode) k => v in (headers):
                drain.receive(b`$k: $v$\r$\n`)
            drain.receive(b`$\r$\n`)

        to send(verb :Str):
            def endpoint := makeTCP4ClientEndpoint(host, port)
            def [fount, drain] := endpoint.connect()
            def [p, r] := Ref.promise()

            # Write request.
            when (drain) ->
                request.write(verb, drain)
            # Read response.
            fount<-flowTo(makeResponseDrain(r))

            return p

        to get():
            return request.send("GET")


def main(argv, => getAddrInfo, => makeTCP4ClientEndpoint) as DeepFrozen:
    def addrs := getAddrInfo(b`example.com`, b``)
    return when (addrs) ->
        def gai := makeGAI(addrs)
        def [addr] + _ := gai.TCP4()
        def response := makeRequest(makeTCP4ClientEndpoint, addr.getAddress(), "/").get()
        when (response) ->
            traceln("Finished request with response", response)
            def drain := makePureDrain()
            response<-flowTo(drain)
            traceln("Getting body...")
            when (def pieces := drain<-promisedItems()) ->
                traceln(`Pieces: $pieces`)
                0
    catch problem:
        traceln(`Problem: $problem`)
        traceln.exception(problem)
        1
