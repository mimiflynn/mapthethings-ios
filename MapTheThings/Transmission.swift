//
//  Transmission.swift
//  MapTheThings
//
//  Created by Frank on 2017/1/1.
//  Copyright © 2017 The Things Network New York. All rights reserved.
//

import CoreData
import Foundation
import MapKit
import Alamofire
import PromiseKit
import ReactiveCocoa

public class Transmission: NSManagedObject {
    @NSManaged var created: NSDate

    @NSManaged var latitude: Double
    @NSManaged var longitude: Double
    @NSManaged var altitude: Double
    @NSManaged var packet: NSData?

    // When node reports transmission, store seq_no
    @NSManaged var dev_eui: String
    @NSManaged var seq_no: NSNumber?

    // Date transmission was stored at server
    @NSManaged var synced: NSDate?
    
    static var syncWorkDisposer: Disposable?
    static var syncDisposer: Disposable?
    static var recordWorkDisposer: Disposable?
    static var recordDisposer: Disposable?
    
    override public func awakeFromInsert() {
        super.awakeFromInsert()
        created = NSDate()
    }
    
    public static func create(
        dataController: DataController,
        latitude: Double, longitude: Double, altitude: Double,
        packet: NSData, device: NSUUID
        ) throws -> Transmission {
        return try dataController.performAndWaitInContext() { moc in
            let tx = NSEntityDescription.insertNewObjectForEntityForName("Transmission", inManagedObjectContext: moc) as! Transmission
            tx.latitude = latitude
            tx.longitude = longitude
            tx.altitude = altitude
            tx.packet = packet
            tx.dev_eui = device.UUIDString
            tx.seq_no = nil
            try moc.save()
            return tx
        }
    }
    
    public static func loadTransmissions(data: DataController) {
        // NOTE: The following code represents a pattern regarding idempotency of work
        // that is emerging in the AppState logic. I expect I'll add some code to 
        // explicitly support the pattern when I get a chance.
        
        // Recognize that there is work to do and flag that it should happen
        self.syncWorkDisposer = appStateObservable.observeNext { (old, new) in
            if (!new.syncState.syncWorking
                && new.syncState.syncPendingCount>0) {
                // Don't just start async work here. There's a chance with 
                // multiple enqueued updates to AppState that this method will be called 
                // many times in the same state of needing to start work. We wouldn't want to 
                // start doing the same work every time.
                updateAppState({ (old) -> AppState in
                    var state = old
                    state.syncState.syncWorking = true
                    return state
                })
            }
        }
        
        // Recognize that the work flag went up and do the work.
        self.syncDisposer = appStateObservable.observeNext { (old, new) in
            if (!old.syncState.syncWorking && new.syncState.syncWorking) {
                debugPrint("Sync one: \(new.syncState)")
                syncOneTransmission(data, host: new.host)
            }
        }

        // Recognize that there is work to do and flag that it should happen
        self.recordWorkDisposer = appStateObservable.observeNext { (old, new) in
            if (!new.syncState.recordWorking
                && new.syncState.recordLoraToObject.count>0) {
                updateAppState({ (old) -> AppState in
                    var state = old
                    state.syncState.recordWorking = true
                    return state
                })
            }
        }
        
        // Recognize that the work flag went up and do the work.
        self.recordDisposer = appStateObservable.observeNext { (old, new) in
            if (!old.syncState.recordWorking && new.syncState.recordWorking) {
                debugPrint("Record one: \(new.syncState)")
                recordOneLoraSeqNo(data, update: new.syncState.recordLoraToObject)
            }
        }

        data.performInContext() { moc in
            do {
                let fetch = NSFetchRequest(entityName: "Transmission")
                let calendar = NSCalendar.autoupdatingCurrentCalendar()
                let now = NSDate()
                if let earlier = calendar.dateByAddingUnit(.Hour, value: -8, toDate: now, options: []) {
                    fetch.predicate = NSPredicate(format: "created > %@", earlier)
                    let transmissions = try moc.executeFetchRequest(fetch) as! [Transmission]
                    let samples = transmissions.map { (tx) in
                        return TransSample(location: CLLocationCoordinate2D(latitude: tx.latitude, longitude: tx.longitude), altitude: tx.altitude, timestamp: tx.created,
                            device: nil, ble_seq: nil, // Not live transmission, so nil OK
                            lora_seq: tx.seq_no?.unsignedIntValue, objectID: nil)
                    }
                    
                    updateAppState({ (old) -> AppState in
                        var state = old
                        state.map.transmissions = samples
                        return state
                    })
                }
 
                fetch.predicate = NSPredicate(format: "synced = nil and seq_no != nil")
                let syncReady = try moc.countForFetchRequest(fetch)
                updateAppState { old in
                    var state = old
                    state.syncState.syncPendingCount = syncReady
                    return state
                }
                fetch.predicate = NSPredicate(format: "synced = nil")
                let unsynced = try moc.countForFetchRequest(fetch)
                debugPrint("Transmissions without node confirmation: \(unsynced)")
            }
            catch let error as NSError {
                setAppError(error, fn: "loadTransmissions", domain: "database")
            }
            catch let error {
                let nserr = NSError(domain: "database", code: 1, userInfo: [NSLocalizedDescriptionKey: "\(error)"])
                setAppError(nserr, fn: "loadTransmissions", domain: "database")
            }
        }
    }
    
    static func recordOneLoraSeqNo(data: DataController, update: [(NSManagedObjectID, UInt32)]) {
        if (update.isEmpty) {
            return
        }
        data.performInContext() { moc in
            let (objID, loraSeq) = update.first!
            do {
                let tx = try moc.existingObjectWithID(objID) as! Transmission
                tx.seq_no = NSNumber(unsignedInt: loraSeq)
                try moc.save()
            }
            catch let error as NSError {
                setAppError(error, fn: "applicationDidFinishLaunchingWithOptions", domain: "database")
            }
            catch let error {
                let nserr = NSError(domain: "database", code: 1, userInfo: [NSLocalizedDescriptionKey: "\(error)"])
                setAppError(nserr, fn: "applicationDidFinishLaunchingWithOptions", domain: "database")
            }
            updateAppState({ (old) -> AppState in
                var state = old
                state.syncState.recordWorking = false
                state.syncState.recordLoraToObject = state.syncState.recordLoraToObject.filter({ pair -> Bool in
                    return pair.0 != objID
                })
                return state
            })
        }
    }
    
    static func formatterForJSONDate() -> NSDateFormatter {
        let formatter = NSDateFormatter()
        formatter.dateFormat = "yyyy-MM-dd'T'HH:mm:ss.SSS'Z'"
        formatter.timeZone = NSTimeZone(forSecondsFromGMT: 0)
        formatter.locale = NSLocale(localeIdentifier: "en_US_POSIX")
        return formatter
    }

    public static func syncOneTransmission(data: DataController, host: String) {
        data.performInContext() { moc in
            do {
                let fetch = NSFetchRequest(entityName: "Transmission")
                fetch.predicate = NSPredicate(format: "synced = nil and seq_no != nil")
                fetch.fetchLimit = 1
                let transmissions = try moc.executeFetchRequest(fetch) as! [Transmission]
                if (transmissions.count>=1) {
                    postTransmission(transmissions[0], data: data, host: host)
                }
            }
            catch let error as NSError {
                setAppError(error, fn: "applicationDidFinishLaunchingWithOptions", domain: "database")
            }
            catch let error {
                let nserr = NSError(domain: "database", code: 1, userInfo: [NSLocalizedDescriptionKey: "\(error)"])
                setAppError(nserr, fn: "applicationDidFinishLaunchingWithOptions", domain: "database")
            }
        }
    }

    public static func postTransmission(tx: Transmission, data: DataController, host: String) {
        let formatter = formatterForJSONDate()
        let params = Promise<[String:AnyObject]>{ fulfill, reject in
            data.performInContext() { _ in
                // Access database object within moc queue
                let parameters = [
                    "lat": tx.latitude,
                    "lon": tx.longitude,
                    "alt": tx.altitude,
                    "timestamp": formatter.stringFromDate(tx.created),
                    "dev_eui": tx.dev_eui,
                    "msg_seq": tx.seq_no!,
                ]
                fulfill(parameters)
            }
        }
        params.then { parameters -> Promise<NSDictionary> in
            debugPrint("Params: \(parameters)")
            let url = "http://\(host)/api/v0/transmissions"
            debugPrint("URL: \(url)")
            let rsp = Promise<NSDictionary> { fulfill, reject in
                request(.POST, url,
                    parameters: parameters,
                    encoding: ParameterEncoding.JSON)
                .responseJSON(queue: nil, options: .AllowFragments, completionHandler: { response in
                    switch response.result {
                    case .Success(let value):
                        fulfill(value as! NSDictionary)
                    case .Failure(let error):
                        reject(error)
                    }
                })
            }
            return rsp
        }.then { jsonResponse -> Void in
            debugPrint(jsonResponse)
            // Write sync time to tx
            try data.performAndWaitInContext() { moc in
                let now = NSDate()
                tx.synced = now
                try moc.save()
                updateAppState({ (old) -> AppState in
                    var state = old
                    state.syncState.lastPost = now
                    if (state.syncState.syncPendingCount>0) {
                        state.syncState.syncPendingCount -= 1;
                    }
                    state.syncState.syncWorking = false
                    return state
                })
            }
        }.error { (error) in
            debugPrint("\(error)")
            setAppError(error, fn: "postTransmission", domain: "web")
            updateAppState({ (old) -> AppState in
                var state = old
                state.syncState.lastPost = NSDate()
                state.syncState.syncWorking = false
                return state
            })
        }
    }
}
