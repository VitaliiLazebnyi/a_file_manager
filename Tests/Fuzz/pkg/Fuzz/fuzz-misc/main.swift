import FuzzCore

// Target group 5: descript.ion, tab files, selection files, settings import and the lenient
// decoders of stored settings, parameter expansion, and the shell-quoting property.

fuzzMain([
    QuoteDemoTarget.make(),
    DescriptTarget.make(),
    DescriptLineTarget.make(),
    DescriptStoreTarget.make(),
    TabFileTarget.make(),
    SelectionTarget.make(),
    SettingsTarget.make(),
    LenientTarget.make(),
    PexpandTarget.make(),
    QuoteTarget.make()
])
