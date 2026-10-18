import Foundation
import SwiftData
import OSLog

/// Utility to import clients and pets from CSV data.
/// Supports a flexible mapping of columns.
final class ImportService {
    static let shared = ImportService()
    
    struct ImportResult {
        let clientsCreated: Int
        let petsCreated: Int
        let errors: [String]
    }
    
    @MainActor
    func importFromCSV(data: String, context: ModelContext) throws -> ImportResult {
        let lines = data.components(separatedBy: .newlines)
        guard lines.count > 1 else { return ImportResult(clientsCreated: 0, petsCreated: 0, errors: ["Empty file"]) }
        
        let header = lines[0].components(separatedBy: ",")
        var clientsCreated = 0
        var petsCreated = 0
        let errors: [String] = []
        
        // Simple mapping based on common names
        let firstNameIdx = header.firstIndex(where: { $0.localizedCaseInsensitiveContains("first") })
        let lastNameIdx = header.firstIndex(where: { $0.localizedCaseInsensitiveContains("last") })
        let phoneIdx = header.firstIndex(where: { $0.localizedCaseInsensitiveContains("phone") })
        let petNameIdx = header.firstIndex(where: { $0.localizedCaseInsensitiveContains("pet") })
        let breedIdx = header.firstIndex(where: { $0.localizedCaseInsensitiveContains("breed") })
        
        for (i, line) in lines.enumerated() where i > 0 && !line.isEmpty {
            let cells = line.components(separatedBy: ",")
            
            let firstName = firstNameIdx != nil && cells.count > firstNameIdx! ? cells[firstNameIdx!] : "Unknown"
            let lastName = lastNameIdx != nil && cells.count > lastNameIdx! ? cells[lastNameIdx!] : "Client"
            let phone = phoneIdx != nil && cells.count > phoneIdx! ? cells[phoneIdx!] : ""
            
            let client = Client(firstName: firstName, lastName: lastName, phone: phone)
            context.insert(client)
            clientsCreated += 1
            
            if let petIdx = petNameIdx, cells.count > petIdx {
                let petName = cells[petIdx]
                if !petName.isEmpty {
                    let newPet = Pet(name: petName, species: Species.dog)
                    if let bIdx = breedIdx, cells.count > bIdx {
                        newPet.setBreed(cells[bIdx])
                    }
                    newPet.owner = client
                    context.insert(newPet)
                    petsCreated += 1
                }
            }
        }
        
        try context.save()
        return ImportResult(clientsCreated: clientsCreated, petsCreated: petsCreated, errors: errors)
    }
}
