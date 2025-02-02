/**
 * Copyright IBM Corporation 2017
 *
 * Licensed under the Apache License, Version 2.0 (the "License");
 * you may not use this file except in compliance with the License.
 * You may obtain a copy of the License at
 *
 * http://www.apache.org/licenses/LICENSE-2.0
 *
 * Unless required by applicable law or agreed to in writing, software
 * distributed under the License is distributed on an "AS IS" BASIS,
 * WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
 * See the License for the specific language governing permissions and
 * limitations under the License.
 **/

import Kitura
import SwiftMetricsKitura
import SwiftMetricsBluemix
import SwiftMetrics
import KituraNet
import KituraWebSocket
import Foundation
import Configuration
import CloudFoundryEnv
import Dispatch

struct HTTPAggregateData: SMData {
    public var timeOfRequest: Int64 = 0
    public var url: String = ""
    public var longest: Double = 0
    public var average: Double = 0
    public var total: Int = 0
}
var router = Router()
public class SwiftMetricsDash {

    var monitor:SwiftMonitor
    var SM:SwiftMetrics
    var service:SwiftMetricsService
    var createServer: Bool = false

    public convenience init(swiftMetricsInstance : SwiftMetrics) throws {
        try self.init(swiftMetricsInstance : swiftMetricsInstance , endpoint: nil)
    }

    public init(swiftMetricsInstance : SwiftMetrics , endpoint: Router!) throws {
        // default to use passed in Router
        if endpoint == nil {
            self.createServer = true
        } else {
            router =  endpoint
        }
        self.SM = swiftMetricsInstance
        _ = SwiftMetricsKitura(swiftMetricsInstance: SM)
        self.monitor = SM.monitor()
        self.service = SwiftMetricsService(monitor: monitor)
        WebSocket.register(service: self.service, onPath: "swiftmetrics-dash")

        try startServer(router: router)
    }

    deinit {
        if self.createServer {
            Kitura.stop()
        }
    }

    func startServer(router: Router) throws {
        router.all("/swiftmetrics-dash", middleware: StaticFileServer(path: self.SM.localSourceDirectory + "/public"))

        if self.createServer {
            let configMgr = ConfigurationManager().load(.environmentVariables)
            Kitura.addHTTPServer(onPort: configMgr.port, with: router)
            print("SwiftMetricsDash : Starting on port \(configMgr.port)")
            Kitura.start()
        }
    }
}
class SwiftMetricsService: WebSocketService {

    private var connections = [String: WebSocketConnection]()
    var httpAggregateData: HTTPAggregateData = HTTPAggregateData()
    var httpURLData:[String:(totalTime:Double, numHits:Double, longestTime:Double)] = [:]
    let httpURLsQueue = DispatchQueue(label: "httpURLsQueue")
    let httpQueue = DispatchQueue(label: "httpStoreQueue")
    let jobsQueue = DispatchQueue(label: "jobsQueue")
    var monitor:SwiftMonitor

    // CPU summary data
    var totalProcessCPULoad: Double = 0.0;
    var totalSystemCPULoad: Double = 0.0;
    var cpuLoadSamples: Double = 0

    // Memory summary data
    var totalProcessMemory: Int = 0;
    var totalSystemMemory: Int = 0;
    var memorySamples: Int = 0;

    //countdown timer
    let countdownTimer: DispatchSourceTimer = DispatchSource.makeTimerSource();

    public init(monitor: SwiftMonitor) {
        self.monitor = monitor
        monitor.on(sendCPU)
        monitor.on(sendMEM)
        monitor.on(storeHTTP)
        httpTimerStart()
    }



    func sendCPU(cpu: CPUData) {
        totalProcessCPULoad += Double(cpu.percentUsedByApplication);
        totalSystemCPULoad += Double(cpu.percentUsedBySystem);
        cpuLoadSamples += 1;
        let processMean = (totalProcessCPULoad / cpuLoadSamples);
        let systemMean = (totalSystemCPULoad / cpuLoadSamples);

        let cpuLine =
            "{\"topic\":\"cpu\"," +
                "\"payload\":{" +
                "\"process\":\"\(cpu.percentUsedByApplication)\"," +
                "\"systemMean\":\"\(systemMean)\"," +
                "\"processMean\":\"\(processMean)\"," +
                "\"time\":\"\(cpu.timeOfSample)\"," +
                "\"system\":\"\(cpu.percentUsedBySystem)\"" +
        "}}"

        for (_,connection) in connections {
            connection.send(message: cpuLine)
        }

    }


    func sendMEM(mem: MemData) {
        totalProcessMemory += mem.applicationRAMUsed;
        totalSystemMemory += mem.totalRAMUsed;
        memorySamples += 1;
        let processMean = (totalProcessMemory / memorySamples);
        let systemMean = (totalSystemMemory / memorySamples);

        let memLine =
            "{\"topic\":\"memory\"," +
                "\"payload\":{" +
                "\"time\":\"\(mem.timeOfSample)\"," +
                "\"physical\":\"\(mem.applicationRAMUsed)\"," +
                "\"physical_used\":\"\(mem.totalRAMUsed)\"," +
                "\"processMean\":\"\(processMean)\"," +
                "\"systemMean\":\"\(systemMean)\"" +
        "}}"

        for (_,connection) in connections {
            connection.send(message: memLine)
        }
    }

    public func connected(connection: WebSocketConnection) {
        connections[connection.id] = connection
        getenvRequest()
        sendTitle()
    }

    public func disconnected(connection: WebSocketConnection, reason: WebSocketCloseReasonCode){}

    public func received(message: Data, from : WebSocketConnection){}

    public func received(message: String, from : WebSocketConnection){
        print("SwiftMetricsService -- \(message)")
    }


    public func getenvRequest()  {
        var commandLine = ""
        var hostname = ""
        var os = ""
        var numPar = ""

        for (param, value) in self.monitor.getEnvironmentData() {
            switch param {
            case "command.line":
                commandLine = value
                break
            case "environment.HOSTNAME":
                hostname = value
                break
            case "os.arch":
                os = value
                break
            case "number.of.processors":
                numPar = value
                break
            default:
                break
            }
        }


        let envLine =
            "{\"topic\":\"env\",\"payload\":[" +
                "{\"Parameter\":\"Command Line\",\"Value\":\"\(commandLine)\"}," +
                "{\"Parameter\":\"Hostname\",\"Value\":\"\(hostname)\"}," +
                "{\"Parameter\":\"Number of Processors\",\"Value\":\"\(numPar)\"}," +
                "{\"Parameter\":\"OS Architecture\",\"Value\":\"\(os)\"}" +
        "]}"

        for (_,connection) in connections {
            connection.send(message: envLine)
        }
    }


    public func sendTitle()  {
        let titleLine =
            "{\"topic\":\"title\",\"payload\":{" +
                "\"title\":\"Application Metrics for Swift\"," +
                "\"docs\": \"http://github.com/RuntimeTools/SwiftMetrics\"" +
        "}}"

        for (_,connection) in connections {
            connection.send(message: titleLine)
        }
    }

    public func storeHTTP(myhttp: HTTPData) {
        let localmyhttp = myhttp
        let urlWithVerb = localmyhttp.requestMethod + " " + localmyhttp.url
        httpQueue.sync {
            if self.httpAggregateData.total == 0 {
                self.httpAggregateData.total = 1
                self.httpAggregateData.timeOfRequest = localmyhttp.timeOfRequest
                self.httpAggregateData.url = localmyhttp.url
                self.httpAggregateData.longest = localmyhttp.duration
                self.httpAggregateData.average = localmyhttp.duration
            } else {
                let oldTotalAsDouble:Double = Double(self.httpAggregateData.total)
                let newTotal = self.httpAggregateData.total + 1
                self.httpAggregateData.total = newTotal
                self.httpAggregateData.average = (self.httpAggregateData.average * oldTotalAsDouble + localmyhttp.duration) / Double(newTotal)
                if (localmyhttp.duration > self.httpAggregateData.longest) {
                    self.httpAggregateData.longest = localmyhttp.duration
                    self.httpAggregateData.url = localmyhttp.url
                }
            }
        }
        httpURLsQueue.async {
            let urlTuple = self.httpURLData[urlWithVerb]
            if(urlTuple != nil) {
                let averageResponseTime = urlTuple!.0
                let hits = urlTuple!.1
                var longest = urlTuple!.2
                if (localmyhttp.duration > longest) {
                    longest = localmyhttp.duration
                }
                // Recalculate the average
                self.httpURLData.updateValue(((averageResponseTime * hits + localmyhttp.duration)/(hits + 1), hits + 1, longest), forKey: urlWithVerb)
            } else {
                self.httpURLData.updateValue((localmyhttp.duration, 1, localmyhttp.duration), forKey: urlWithVerb)
            }
        }
    }

    func sendhttpData()  {
        httpQueue.sync {
            let localCopy = self.httpAggregateData
            if localCopy.total > 0 {
                let httpLine =
                    "{\"topic\":\"http\",\"payload\":{" +
                        "\"time\":\"\(localCopy.timeOfRequest)\"," +
                        "\"url\":\"\(localCopy.url)\"," +
                        "\"longest\":\"\(localCopy.longest)\"," +
                        "\"average\":\"\(localCopy.average)\"," +
                        "\"total\":\"\(localCopy.total)\"" +
                "}}"

                for (_,connection) in self.connections {
                    connection.send(message: httpLine)
                }
                self.httpAggregateData = HTTPAggregateData()
            }
        }
        httpURLsQueue.sync {
            var responseData:[String] = []
            let localCopy = self.httpURLData
            for (key, value) in localCopy {
                let json =
                    "{\"url\":\"\(key)\"," +
                        "\"averageResponseTime\":\(String(value.0))," +
                        "\"hits\":\(String(value.1))," +
                "\"longestResponseTime\":\(String(value.2))}"
                responseData.append(json)
            }
            var messageToSend:String=""

            // build up the messageToSend string
            for response in responseData {
                messageToSend += response + ","
            }

            if !messageToSend.isEmpty {
                // remove the last ','
                messageToSend = String(messageToSend[..<messageToSend.index(before: messageToSend.endIndex)])
                // construct the final JSON obkect
                let messageToSend2 = "{\"topic\":\"httpURLs\",\"payload\":[" + messageToSend + "]}"
                for (_,connection) in self.connections {
                    connection.send(message: messageToSend2)
                }
            }
        }
    }

    func httpTimerStart() {
        countdownTimer.schedule(deadline: .now(), repeating: .seconds(2), leeway: .milliseconds(100))
        countdownTimer.setEventHandler(handler: self.sendhttpData)
        countdownTimer.resume()
    }

}
