extension MOSParameterDefinition {
    /// Whether a source-supplied scalar may be varied by fresh source execution.
    public var supportsScalarPerturbation: Bool {
        guard kind == .real else { return false }
        return canonicalName != "ic" && canonicalName != "ic_vds"
            && canonicalName != "ic_vgs" && canonicalName != "ic_vbs"
    }
}
