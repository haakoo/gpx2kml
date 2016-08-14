# encoding: utf-8
$:.unshift(File.dirname(__FILE__))

require 'rubygems'
require 'nokogiri'
require 'douglas_peucker'
require 'mini_exiftool'

class Gpx2kml

  def initialize
    @coords   = Array.new
    @pictures = Array.new
  end

  attr :coords

  # Add gpx files
  def add_files(files)
    @files = files.split(',')
  end

  def add_pictures(path)
    Dir.glob("#{path}/*.{jpg,png}", File::FNM_CASEFOLD).each do |f|
      @pictures << f
    end
  end

  # Save to kml file
  def save(filename)
    f = File.open(filename, 'w')
    f.puts @kml.to_xml
    f.close
  end

  # Build kml
  def build_kml(epsylon)
    if epsylon.nil?
      epsylon = 30e-5
    end
    epsylon = epsylon.to_f

    @styles = build_styles()

    @kml = Nokogiri::XML::Builder.new(:encoding => 'UTF-8') do |xml|
      xml.kml('xmlns' => 'http://www.opengis.net/kml/2.2',
              'xmlns:gx' => 'http://www.google.com/kml/ext/2.2',
              'xmlns:kml' => 'http://www.opengis.net/kml/2.2',
              'xmlns:atom' => 'http://www.w3.org/2005/Atom') do

        xml.Document do
          xml.name "Converted from GPX file"
          xml.description {
            xml.cdata "<p>Converted using <b><a href='http://github.com/shakaman/gpx2kml' title='Go to gpx2kml on github'>Github</a></b></p>"
          }
          xml.visibility 1
          xml.open 1

          # Styles
          @styles.each do |s|
            xml.Style(:id => s[:id]) {
              xml.LineStyle {
                xml.color_    s[:LineStyle][:color]
                xml.width_    s[:LineStyle][:width]
              }
            }
          end

          # Tracks
          xml.Folder do
            xml.name "Tracks"
            xml.description "A list of tracks"
            xml.visibility 1
            xml.open 0

            i = 0
            @files.each do |gpx|
              detail = read_gpx(gpx)

              xml.Placemark do
                xml.visibility 0
                xml.open 0
                xml.styleUrl "##{@styles[i][:id]}"
                xml.name detail[:title]
                xml.description detail[:desc]
                xml.LineString do
                  xml.extrude true
                  xml.tessellate true
                  xml.altitudeMode "clampToGround"
                  xml.coordinates format_track(detail[:coords], epsylon)
                end
              end
              i += 1
            end

            @pictures.each do |picture|
              exif = get_exif_picture(picture)

              unless exif[:lon].nil? && exif[:lat].nil?
                xml.Placemark do
                  xml.name exif[:name]
                  xml.description exif[:camera]
                  xml.Point do
                    xml.coordinates "#{exif[:lon]},#{exif[:lat]}"
                  end
                end
              end
            end
          end
        end
      end
    end
  end

  def get_kml
    @kml.to_xml
  end

  # Create track style
  def build_styles
    styles = Array.new
    styles << { id: 'red',    LineStyle: { color: 'C81400FF', width: 4 } }
    styles << { id: 'blue',   LineStyle: { color: 'C8FF7800', width: 4 } }
    styles << { id: 'pink',   LineStyle: { color: '96F0FF14', width: 4 } }
    styles << { id: 'green',  LineStyle: { color: 'C878FF00', width: 4 } }
    styles << { id: 'orange', LineStyle: { color: 'C81478FF', width: 4 } }
    styles << { id: 'dark_green', LineStyle: { color: '96008C14', width: 4 } }
    styles << { id: 'pink2', LineStyle: { color: 'C8A078F0', width: 4 } }
  end

  def read_gpx(path)
    coords = Array.new

    f = File.new(path)
    gpx = Nokogiri::XML(f)
    gpx.remove_namespaces!
    error_count = 0

    trackpoints = gpx.xpath('//gpx/trk/trkseg/trkpt')
    trackpoints.each do |wpt|
      w = {
        :lat => wpt.xpath('@lat').to_s.to_f,
        :lon => wpt.xpath('@lon').to_s.to_f,
        :time => self.class.proc_time(wpt.xpath('time').children.first.to_s),
        :alt => wpt.xpath('ele').children.first.to_s.to_f
      }

      if self.class.coord_valid?(w[:lat], w[:lon], w[:alt], w[:time])
        coords << w
      else
        error_count += 1
      end
    end

    f.close
    coords = coords.sort { |b, c| b[:time] <=> c[:time] }

    {title: gpx.xpath('//gpx/trk/name').text, desc: gpx.xpath('//gpx/trk/desc').text, coords: coords}
  end


  # format coords to track format
  def format_track(coords, epsylon)
    points = Array.new

    coords.each do |c|
      points << {lon: c[:lon], lat: c[:lat], alt: c[:alt]}
    end
    points_list = DouglasPeucker.new(epsylon).simplify_line(points)

    track = ""
    points_list.each do |c|
      track << "#{c[:lon]}, #{c[:lat]}, #{c[:alt]} "
    end

    return track
  end


  def get_exif_picture(picture)
    picture = MiniExiftool.new picture

    lat_dms   = picture['GPSLatitude']
    long_dms  = picture['GPSLongitude']

    latitude  = dms_to_decimal(lat_dms)
    longitude = dms_to_decimal(long_dms)

    latitude  *= -1   if picture['GPSLatitudeRef'] == 'S'
    longitude *= -1   if picture['GPSLongitudeRef'] == 'West'

    {
      lon:        longitude,
      lat:        latitude,
      name:       picture['filename'],
      camera:     picture['model'],
      date_time:  picture['DateTimeOriginal']
    }
  end

  def dms_to_decimal(dms)
    unless dms.nil?
      dms = dms.match(/(\d+) (?:deg|) (\d+)' (\d+\.\d+)/)
      degree = dms[1].to_f
      minute = dms[2].to_f/60
      second = dms[3].to_f/3600

      return degree + minute + second
    end
  end

  # Only import valid coords
  def self.coord_valid?(lat, lon, elevation, time)
    return true if lat and lon
    return false
  end

  def self.proc_time(ts)
    if ts =~ /(\d{4})-(\d{2})-(\d{2})T(\d{1,2}):(\d{2}):(\d{2})Z/
      return Time.gm($1.to_i, $2.to_i, $3.to_i, $4.to_i, $5.to_i, $6.to_i).localtime
    end
  end
end
