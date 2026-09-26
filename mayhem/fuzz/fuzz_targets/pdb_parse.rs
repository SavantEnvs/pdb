#![no_main]
use libfuzzer_sys::fuzz_target;
use pdb::FallibleIterator;

fuzz_target!(|data: &[u8]| {
    let source = std::io::Cursor::new(data);
    if let Ok(mut p) = pdb::PDB::open(source) {
        if let Ok(info) = p.pdb_information() {
            if let Ok(names) = info.stream_names() {
                for name in &names {
                    let _stream = p.raw_stream(name.stream_id);
                }
            }
        }

        if let Ok(type_info) = p.type_information() {
            let mut iter = type_info.iter();
            while let Ok(Some(typ)) = iter.next() {
                let _ = typ.parse();
            }
        }

        if let Ok(id_info) = p.id_information() {
            let mut iter = id_info.iter();
            while let Ok(Some(id)) = iter.next() {
                let _ = id.parse();
            }
        }

        if let Ok(dbg_info) = p.debug_information() {
            let _ = dbg_info.machine_type();
            let _ = dbg_info.age();
            if let Ok(mut mod_iter) = dbg_info.modules() {
                while let Ok(Some(module)) = mod_iter.next() {
                    let _ = module.module_name();
                    let _ = module.object_file_name();
                }
            }
            if let Ok(mut dbi_iter) = dbg_info.section_contributions() {
                while let Ok(Some(_dbi)) = dbi_iter.next() {}
            }
        }
    }
});
