import SwiftUI

/** Job Settings: name and scale (only a scale that parses saves), Calibrate, Export, and Clear all runs. */
struct JobConfigView: View {
    let model: JobModel
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var scale = ""

    var body: some View {
        let valid = parseScale(scale) != nil
        let fromPlan = model.job.foundScale.map { parseScale($0) == parseScale(scale) } == true
        Form {
            if !model.job.scaleSet {
                Text("Set the drawing scale, or calibrate from a known dimension.").foregroundStyle(.secondary)
            }
            Section {
                TextField("Name", text: $name)
                TextField("Scale", text: $scale)
            } footer: {
                Group {
                    if !valid { Text("Write it like 1/4\" = 1'.").foregroundStyle(.red) }
                    else if fromPlan { Text("Loaded from the plan.") }
                    else { Text("e.g. 1/4\" = 1', 1/8\" = 1', 3/4\" = 1'") }
                }
                .foregroundStyle(.secondary)
            }
            Section {
                Button("Calibrate from a Known Length…") { dismiss(); model.startCalibration() }
                    .disabled(model.bitmap == nil)
                Button("Export Quote Spreadsheet…") { exportQuote(model) }
                    .disabled(!canExport(model))
                Button("Clear All Runs…", role: .destructive) { dismiss(); model.confirmClear = true }
                    .disabled(model.job.runs.isEmpty)
            }
        }
        .formStyle(.grouped)
        .frame(width: 420)
        .navigationTitle("Job Settings")
        .toolbar {
            ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
            ToolbarItem(placement: .confirmationAction) {
                Button("Save") { model.saveConfig(name: name, scale: scale); dismiss() }
                    .disabled(name.trimmed.isEmpty || !valid)
            }
        }
        .onAppear { name = model.job.name; scale = model.job.scale }
    }
}
