require 'socket'
require 'json'

# 기존에 돌고 있는 타이머와 서버가 있다면 깔끔하게 종료
UI.stop_timer($my_timer) if $my_timer
$skp_server.close if $skp_server rescue nil

# 아주 가벼운 순수 TCP 소켓 서버 오픈
$skp_server = TCPServer.new('localhost', 4567)
puts "🚀 무한로딩 방지형 로컬 서버 가동 완료! (포트: 4567)"

# 0.1초마다 스케치업 메인 스레드에서 직접 확인 (스레드 충돌 완벽 방지)
$my_timer = UI.start_timer(0.1, true) do
  begin
    # 접속자가 있는지 확인 (없으면 바로 다음으로 넘어감 = non-block)
    client = $skp_server.accept_nonblock
    request_line = client.gets
    
    if request_line
      # 헤더(Header) 정보 읽어오기
      headers = {}
      while line = client.gets and line !~ /^\s*$/
        key, value = line.strip.split(/:\s*/, 2)
        headers[key.downcase] = value if key && value
      end
      
      if request_line.start_with?('OPTIONS')
        # 브라우저 보안(CORS) 검사 통과
        response = "HTTP/1.1 200 OK\r\nAccess-Control-Allow-Origin: *\r\nAccess-Control-Allow-Methods: POST, OPTIONS\r\nAccess-Control-Allow-Headers: Content-Type\r\n\r\n"
        client.print response
        client.close
        
      elsif request_line.start_with?('POST')
        # 데이터가 들어왔을 때 (버튼을 눌렀을 때)
        body_length = headers['content-length'].to_i
        body = client.read(body_length)
        data = JSON.parse(body)
        
        # 모델링 시작
        model = Sketchup.active_model
        model.start_operation('External Build', true)
        
        # =====================================================
        # [호환성] polygon/height 단독 형식 → buildings 배열로 정규화
        # mass.py 구버전 JSON 또는 루비 콘솔 직접 입력 지원
        # =====================================================
        if data['polygon'] && !data['buildings']
          puts "ℹ️ polygon 형식 감지 → buildings 배열로 자동 변환"
          data['buildings'] = [{
            'coordinates' => data['polygon'],
            'height'      => data['height'].to_f,
            'floors'      => (data['floors'] || 1).to_i,
            'name'        => (data['building_type'] || '계획 매스'),
            'usage'       => (data['zone'] || '')
          }]
        end
        
        if data['map'] && data['map']['url']
          begin
            require 'net/http'
            require 'uri'
            require 'openssl'
            
            map_data = data['map']
            url = URI.parse(map_data['url'])
            
            puts "⏳ V-World 위성 지도 다운로드 중..."
            http = Net::HTTP.new(url.host, url.port)
            http.use_ssl = (url.scheme == 'https')
            http.verify_mode = OpenSSL::SSL::VERIFY_NONE
            
            request = Net::HTTP::Get.new(url.request_uri)
            response = http.request(request)
            
            if response.code == "200"
              temp_folder = ENV['TEMP'] || ENV['TMP'] || 'C:/Temp'
              Dir.mkdir(temp_folder) unless Dir.exist?(temp_folder)
              
              img_path = File.join(temp_folder, 'vworld_map_tile.jpg')
              File.binwrite(img_path, response.body)

              if data['terrain'] && data['terrain']['points']
                grid_size = data['terrain']['gridSize'].to_i
                points = data['terrain']['points']
                
                tw_inch = map_data['width'].to_f * 39.3701
                th_inch = map_data['height'].to_f * 39.3701
                
                mesh = Geom::PolygonMesh.new(grid_size * grid_size, (grid_size - 1) * (grid_size - 1) * 2)
                p_indices = []
                
                points.each do |pt|
                  x = (pt['x'].to_f * 39.3701) + (tw_inch / 2.0)
                  y = (pt['y'].to_f * 39.3701) + (th_inch / 2.0)
                  z = pt['z'].to_f * 39.3701
                  p_indices << mesh.add_point(Geom::Point3d.new(x, y, z))
                end
                
                (0...grid_size-1).each do |i|
                  (0...grid_size-1).each do |j|
                    p1 = p_indices[i * grid_size + j]
                    p2 = p_indices[i * grid_size + (j + 1)]
                    p3 = p_indices[(i + 1) * grid_size + j]
                    p4 = p_indices[(i + 1) * grid_size + (j + 1)]
                    
                    mesh.add_polygon(p1, p2, p3)
                    mesh.add_polygon(p2, p4, p3)
                  end
                end
                
                group = model.active_entities.add_group
                group.name = "3D 위성지형(Terrain)"
                group.entities.add_faces_from_mesh(mesh, 0)
                
                mat = model.materials.add("Terrain_Map_#{Time.now.to_i}")
                mat.texture = img_path
                mat.texture.size = [tw_inch, th_inch]
                
                group.entities.grep(Sketchup::Face).each do |f|
                  pt_array = []
                  vs = f.outer_loop.vertices
                  3.times do |k|
                    pos = vs[k].position
                    pt_array << pos
                    pt_array << Geom::Point3d.new(pos.x, pos.y, 0)
                  end
                  begin
                    f.position_material(mat, pt_array, true)
                  rescue => uv_err
                  end
                end
                
                group.entities.grep(Sketchup::Edge).each do |edge|
                  edge.soft = true
                  edge.smooth = true
                  edge.hidden = true
                end
                
                tr = Geom::Transformation.translation(Geom::Vector3d.new(-tw_inch/2.0, -th_inch/2.0, 0))
                group.transform!(tr)
                puts "✅ 3D 표고 기반 지형 모델링 및 위성 매핑 완료!"
              else
                origin = map_data['origin']
                width_inch = map_data['width'].to_f * 39.3701
                height_inch = map_data['height'].to_f * 39.3701
                pt = Geom::Point3d.new(origin[0].to_f * 39.3701, origin[1].to_f * 39.3701, origin[2].to_f * 39.3701)
                img = model.active_entities.add_image(img_path, pt, width_inch, height_inch)
                puts "✅ 2D 위성지도 면 배치 완료"
              end
            else
              puts "⚠️ 지도 다운로드 실패 HTTP #{response.code}"
            end
          rescue => img_err
            puts "⚠️ 지도 시스템 예외 처리: #{img_err.message}"
          end
        end

        # =========================================================
        # 단계 2. 외부 다중 건물 (V-World 데이터 기반) -> 건축적 디테일 적용
        # =========================================================
        if data['buildings'] && data['buildings'].is_a?(Array)
          group = model.active_entities.add_group
          group.name = "도시 건물군 (지형 레벨 적용)"
          success_count = 0
          
          # 루비 머티리얼 준비
          mat_apt = model.materials["Color_Apt"] || model.materials.add("Color_Apt").tap { |m| m.color = "yellow" }
          mat_commercial = model.materials["Color_Comm"] || model.materials.add("Color_Comm").tap { |m| m.color = "orange" }
          mat_public = model.materials["Color_Public"] || model.materials.add("Color_Public").tap { |m| m.color = "blue" }
          mat_house = model.materials["Color_House"] || model.materials.add("Color_House").tap { |m| m.color = "lightgreen" }
          mat_default = model.materials["Color_Default"] || model.materials.add("Color_Default").tap { |m| m.color = "white" }

          data['buildings'].each do |bldg|
            next unless bldg['coordinates'] && bldg['coordinates'].length >= 3
            b_name = bldg['name'] || ""
            usage = bldg['usage'] || ""
            
            # 건물 최고 기준 높이(미터 -> 인치 변환)
            h_inch = bldg['height'].to_f * 39.3701
            h_inch = 118.0 if h_inch <= 0
            
            floors = (bldg['floors'] || 1).to_i
            floors = 1 if floors <= 0
            
            # (1) 건물 바닥 표고 찾기 (레이테스트)
            base_x = bldg['coordinates'][0][0].to_f * 39.3701
            base_y = bldg['coordinates'][0][1].to_f * 39.3701
            
            ray = [Geom::Point3d.new(base_x, base_y, 100000.0), Geom::Vector3d.new(0, 0, -1)]
            hit = model.raytest(ray)
            terrain_z = hit ? hit[0].z : 0.0
            
            anchor_depth = 100.0
            base_z = terrain_z - anchor_depth
            
            # (2) 폴리곤 정점
            pts = bldg['coordinates'].map { |c| [c[0].to_f * 39.3701, c[1].to_f * 39.3701, base_z] }
            
            begin
              face = group.entities.add_face(pts)
              unless face.nil?
                face.reverse! if face.normal.z < 0
                final_push_height = h_inch + anchor_depth
                face.pushpull(final_push_height)
                success_count += 1
                
                target_mat = mat_default
                if b_name.include?("아파트") || usage.include?("공동주택")
                  target_mat = mat_apt
                elsif usage.include?("제1종근린") || usage.include?("제2종근린") || usage.include?("상업") || usage.include?("판매") || b_name.include?("상가") || b_name.include?("프라자")
                  target_mat = mat_commercial
                elsif usage.include?("공공") || usage.include?("업무") || usage.include?("교육") || usage.include?("학교") || b_name.include?("센터")
                  target_mat = mat_public
                elsif usage.include?("단독") || usage.include?("다세대") || usage.include?("주거") || usage.include?("빌라")
                  target_mat = mat_house
                end

                # 추출된 면 전체 색상 할당
                new_faces = face.all_connected.grep(Sketchup::Face)
                new_faces.each { |f| f.material = target_mat }
                
                # ========================================================
                # [디테일] 옥상 코어탑 및 층 별 수평선 모델링 추가
                # ========================================================
                top_face = new_faces.max_by { |f| f.bounds.center.z }
                
                if top_face
                  b_box = top_face.bounds
                  w = b_box.width
                  h = b_box.height
                  if w > 200.0 && h > 200.0
                    cx, cy, cz = b_box.center.x, b_box.center.y, b_box.center.z
                    
                    cw = [w * 0.3, 150.0].min
                    ch = [h * 0.3, 150.0].min
                    
                    core_pts = [
                      Geom::Point3d.new(cx - cw/2, cy - ch/2, cz),
                      Geom::Point3d.new(cx + cw/2, cy - ch/2, cz),
                      Geom::Point3d.new(cx + cw/2, cy + ch/2, cz),
                      Geom::Point3d.new(cx - cw/2, cy + ch/2, cz)
                    ]
                    begin
                      c_face = group.entities.add_face(core_pts)
                      c_face.reverse! if c_face.normal.z < 0
                      c_face.pushpull(120.0) 
                      c_face.all_connected.each { |ent| ent.material = target_mat if ent.is_a?(Sketchup::Face) }
                    rescue
                    end
                  end
                end
                
                if floors > 1 && h_inch > 118.0
                  floor_height = h_inch / floors.to_f
                  vertical_faces = new_faces.select { |f| f.normal.z.abs < 0.1 }
                  
                  (1...floors).each do |f_idx|
                    z_target = base_z + anchor_depth + (f_idx * floor_height)
                    
                    vertical_faces.each do |v_face|
                      next unless v_face.valid?
                      
                      pts_at_z = []
                      v_face.edges.each do |e|
                        start_z = e.start.position.z
                        end_z = e.end.position.z
                        
                        if (start_z < z_target && end_z > z_target) || (end_z < z_target && start_z > z_target)
                          dz = end_z - start_z
                          ratio = (z_target - start_z) / dz
                          x = e.start.position.x + (e.end.position.x - e.start.position.x) * ratio
                          y = e.start.position.y + (e.end.position.y - e.start.position.y) * ratio
                          pts_at_z << Geom::Point3d.new(x, y, z_target)
                        end
                      end
                      
                      if pts_at_z.length == 2
                        begin
                          group.entities.add_edges(pts_at_z[0], pts_at_z[1])
                        rescue
                        end
                      end
                    end
                  end
                end
              end
            rescue => face_err
              puts "⚠️ 지형 맞춤형 건물 생성 오류(#{b_name}): #{face_err.message}"
            end
          end
          puts "✅ 지형/디테일 맞춤형 건물군 #{success_count}채 생성 완료"
        end


        # 단계 4. 도로망(Edges) 3D 지형 위에 물리적 표출 (Drape by Raytest)
        if data['roads'] && data['roads'].is_a?(Array) && data['roads'].length > 0
          begin
            road_group = model.active_entities.add_group
            road_group.name = "도로망 (3D 지형 투영)"
            road_count = 0
            
            data['roads'].each do |road|
              next unless road['coordinates']
              
              projected_pts = []
              road['coordinates'].each do |c|
                x = c[0].to_f * 39.3701
                y = c[1].to_f * 39.3701
                
                # Z축 상단(100,000인치)에서 아래로 레이저 발사
                ray = [Geom::Point3d.new(x, y, 100000.0), Geom::Vector3d.new(0, 0, -1)]
                hit = model.raytest(ray)
                
                if hit
                  # 교차점 찾으면 +5인치 여백 (Z-fighting 방지)
                  projected_pts << Geom::Point3d.new(x, y, hit[0].z + 5.0)
                else
                  projected_pts << Geom::Point3d.new(x, y, 5.0)
                end
              end
              
              if projected_pts.length >= 2
                # 마이크로 엣지 길이에 의한 에러를 피하기 위해 선분을 개별적으로 거리 체크하며 생성
                (0...projected_pts.length - 1).each do |idx|
                  p1 = projected_pts[idx]
                  p2 = projected_pts[idx + 1]
                  
                  # 스케치업은 0.001인치(약 0.02mm) 이하의 엣지는 생성 불가. 넉넉히 0.1인치로 필터링
                  if p1.distance(p2) > 0.1
                    begin
                      road_group.entities.add_line(p1, p2)
                    rescue
                    end
                  end
                end
                road_count += 1
              end
            end
            
            # 머티리얼 적용
            begin
              mat = model.materials["Road_Color"] || model.materials.add("Road_Color")
              mat.color = "yellow"
              road_group.material = mat
            rescue
            end
            
            puts "✅ 3D 지형 위 도로망 선 표출 완료: 총 #{road_count} 구간"
          rescue => err
            puts "⚠️ 도로망 표출 중 오류: #{err.message}"
          end
        end
        
        model.commit_operation
        
        # 웹사이트에 성공했다고 답변 보내기
        response = "HTTP/1.1 200 OK\r\nAccess-Control-Allow-Origin: *\r\nContent-Type: application/json\r\n\r\n{\"status\":\"success\"}"
        client.print response
        client.close
        
      else
        # 직접 주소창에 쳤을 때 (무한로딩 해결!)
        response = "HTTP/1.1 200 OK\r\nContent-Type: text/html; charset=utf-8\r\n\r\n<h1 style='color:green'>✅ 스케치업 통신 서버가 완벽하게 연결되었습니다!</h1><p>이제 외부 컨트롤러에서 데이터를 보내보세요.</p>"
        client.print response
        client.close
      end
    end
  rescue IO::WaitReadable, Errno::EAGAIN, Errno::EWOULDBLOCK
    # 접속자가 없으면 조용히 대기 (정상 상태)
  rescue => e
    puts "에러 발생: #{e.message}"
    client.close rescue nil
  end
end