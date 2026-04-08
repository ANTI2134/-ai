require 'sketchup.rb'

module MassAutomation
  def self.import_cad_and_extrude(cad_file = nil, floor_height_val = nil, selected_unit = nil, num_floors = nil, selected_mode = nil)
    model = Sketchup.active_model
    entities = model.active_entities
    
    # 1. Select CAD File if not provided
    unless cad_file
      cad_file = UI.openpanel("Select CAD File (DWG/DXF)", "", "CAD Files (*.dwg, *.dxf)|*.dwg;*.dxf|All Files (*.*)|*.*||")
      return unless cad_file
    end
    
    # 2. Track existing entities
    existing_entities = entities.to_a
    
    # 3. Import CAD
    options_dialog = cad_file.nil?
    status = model.import(cad_file, options_dialog) rescue false
    
    if !status
      puts "⚠️ Native DXF import skipped or failed (Likely Make version). Switching to custom R12 parser..."
      line_data = parse_dxf_r12_lines(cad_file)
      
      if line_data.empty?
        UI.messagebox("Import failed!\nMake 2017 version requires a Pro license for native DXF import.\nPlease ensure the DXF is saved as R12 (AC1009) format for the custom parser to work.")
        return
      end
      
      # Draw lines manually for Make version
      model.start_operation('Direct DXF Import', true)
      line_data.each do |d|
        p1 = [d[:x1].mm, d[:y1].mm, (d[:z1]||0).mm]
        p2 = [d[:x2].mm, d[:y2].mm, (d[:z2]||0).mm]
        entities.add_line(p1, p2)
      end
      model.commit_operation
      
      # Identify New Entities manually
      new_entities = entities.to_a - existing_entities
    else
      # Identify New Entities from native import
      new_entities = entities.to_a - existing_entities
    end

    # 4. Get User Input for Height and Mode if not provided
    unless floor_height_val && selected_unit && num_floors && selected_mode
      prompts = ["Floor Height:", "Unit:", "Number of Floors:", "Mass Mode:"]
      units_list = "m|cm|mm"
      modes_list = "Each Loop (Detailed)|Unified Envelope (Mass)"
      defaults = [3.5, "m", 1, "Unified Envelope (Mass)"]
      input = UI.inputbox(prompts, defaults, [nil, units_list, nil, modes_list], "Massing Parameters")
      return unless input
      
      floor_height_val = input[0].to_f
      selected_unit = input[1]
      num_floors = input[2].to_i
      selected_mode = input[3]
    end
    
    case selected_unit
    when "mm"
      total_single_height = floor_height_val.mm
    when "cm"
      total_single_height = floor_height_val.cm
    else
      total_single_height = floor_height_val.m
    end
    total_height = total_single_height * num_floors
    
    instances = new_entities.grep(Sketchup::ComponentInstance) + new_entities.grep(Sketchup::Group)
    
    model.start_operation('Create Massing', true)
    begin
      entities_to_process = []
      if instances.empty?
        entities_to_process = new_entities
      else
        instances.each do |inst|
          if inst.valid?
            exploded = inst.explode
            entities_to_process.concat(exploded)
          end
        end
      end
      
      process_entities(entities_to_process, total_height, selected_mode)
      UI.messagebox("Massing completed successfully!")
    rescue => e
      model.abort_operation
      UI.messagebox("Error during massing: #{e.message}")
      puts e.backtrace
    else
      model.commit_operation
    end
  end

  def self.process_entities(entities_list, height, mode)
    # 1. Find edges and create faces
    edges = entities_list.grep(Sketchup::Edge)
    num_edges = edges.length
    edges.each_with_index do |e, index|
      Sketchup.status_text = "Processing edges: #{(index * 100 / num_edges).to_i}%" if index % 100 == 0
      e.find_faces if e.valid?
    end
    
    # 2. Identify new horizontal faces
    all_faces = Sketchup.active_model.active_entities.grep(Sketchup::Face)
    new_faces = all_faces.select { |f| 
      f.valid? && f.normal.parallel?(Z_AXIS) && (f.edges & edges).any? 
    }
    
    if mode.include?("Unified")
      # MASS MODE: Gapless Solid Footprint
      return if new_faces.empty?
      
      # Group faces by Z-level to handle multiple floors accurately
      # (V-World DXF stores each floor at its specific Z elevation)
      faces_by_z = new_faces.group_by { |f| (f.bounds.center.z * 10).round / 10.0 }
      
      faces_by_z.each do |z, z_faces|
        # Step 1: Find the main building footprint for this level (largest area)
        main_face = z_faces.max_by { |f| f.area }
        next unless main_face && main_face.valid?
        
        # Step 2: Delete all inner loops for this specific face to create a solid mass
        # This ensures that even if we have wall thickness, the mass is a solid volume
        inner_loops = main_face.loops - [main_face.outer_loop]
        hole_edges = []
        inner_loops.each { |loop| hole_edges.concat(loop.edges) }
        
        # Erase edges creating the holes for this floor
        Sketchup.active_model.active_entities.erase_entities(hole_edges.uniq.select(&:valid?)) if hole_edges.any?
        
        # Step 3: Re-fetch the face (it might have changed after erasing holes) and extrude
        final_face = Sketchup.active_model.active_entities.grep(Sketchup::Face).select { |f| 
          f.valid? && f.normal.parallel?(Z_AXIS) && ((f.bounds.center.z * 10).round / 10.0 == z)
        }.max_by { |f| f.area }
        
        extrude_face(final_face, height) if final_face
      end
    else
      # DETAILED MODE: Extrude each loop individually
      num_faces = new_faces.length
      new_faces.each_with_index do |face, index|
        next unless face.valid?
        Sketchup.status_text = "Extruding faces: #{(index * 100 / num_faces).to_i}%" if index % 10 == 0
        extrude_face(face, height)
      end
    end
    
    Sketchup.status_text = "Done."
  end

  def self.extrude_face(face, height)
    return unless face.valid?
    begin
      if face.normal.dot(Z_AXIS) > 0
        face.pushpull(height)
      elsif face.normal.dot(Z_AXIS) < 0
        face.pushpull(-height)
      end
    rescue => e
      puts "Skipping a face due to error: #{e.message}"
    end
  end

  # Custom R12 DXF LINE parser fallback for SketchUp Make users
  def self.parse_dxf_r12_lines(file_path)
    entities_data = []
    current_ent = nil
    
    begin
      File.open(file_path, "r:UTF-8") do |f|
        while (line = f.gets)
          l = line.strip
          if l == "0"
            if current_ent && current_ent[:type] == "LINE"
              entities_data << current_ent
            end
            type = f.gets.strip
            current_ent = { type: type }
          elsif current_ent
            code = l.to_i
            val = f.gets.strip
            case code
            when 10 then current_ent[:x1] = val.to_f
            when 20 then current_ent[:y1] = val.to_f
            when 30 then current_ent[:z1] = val.to_f
            when 11 then current_ent[:x2] = val.to_f
            when 21 then current_ent[:y2] = val.to_f
            when 31 then current_ent[:z2] = val.to_f
            end
          end
        end
      end
      if current_ent && current_ent[:type] == "LINE"
        entities_data << current_ent
      end
    rescue => e
      puts "Custom DXF parser error: #{e.message}"
    end
    
    entities_data
  end
end

# Add a menu item to SketchUp
unless file_loaded?(__FILE__)
  menu = UI.menu('Plugins')
  menu.add_item('CAD to Mass') {
    MassAutomation.import_cad_and_extrude
  }
  file_loaded(__FILE__)
end
