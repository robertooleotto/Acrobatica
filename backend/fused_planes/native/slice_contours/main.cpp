#include <CGAL/Exact_predicates_inexact_constructions_kernel.h>
#include <CGAL/IO/polygon_mesh_io.h>
#include <CGAL/IO/polygon_soup_io.h>
#include <CGAL/Polygon_mesh_slicer.h>
#include <CGAL/Polygon_mesh_processing/orient_polygon_soup.h>
#include <CGAL/Polygon_mesh_processing/polygon_soup_to_polygon_mesh.h>
#include <CGAL/Polygon_mesh_processing/repair_polygon_soup.h>
#include <CGAL/Shape_regularization/regularize_contours.h>
#include <CGAL/Shape_regularization/Contours/Longest_direction_2.h>
#include <CGAL/Shape_regularization/Contours/User_defined_directions_2.h>
#include <CGAL/Surface_mesh.h>

#include <cmath>
#include <fstream>
#include <iomanip>
#include <iostream>
#include <sstream>
#include <string>
#include <vector>

using Kernel = CGAL::Exact_predicates_inexact_constructions_kernel;
using Point_2 = Kernel::Point_2;
using Point_3 = Kernel::Point_3;
using Plane_3 = Kernel::Plane_3;
using Mesh = CGAL::Surface_mesh<Point_3>;
using Slicer = CGAL::Polygon_mesh_slicer<Mesh, Kernel>;

namespace Contours = CGAL::Shape_regularization::Contours;
namespace PMP = CGAL::Polygon_mesh_processing;

static bool same_point_2(const Point_2& a, const Point_2& b, const double eps = 1e-7) {
  const double dx = CGAL::to_double(a.x() - b.x());
  const double dy = CGAL::to_double(a.y() - b.y());
  return std::sqrt(dx * dx + dy * dy) <= eps;
}

static double length_2(const std::vector<Point_2>& pts, const bool closed) {
  if (pts.size() < 2) return 0.0;
  double out = 0.0;
  const std::size_t n = pts.size();
  for (std::size_t i = 1; i < n; ++i) {
    const double dx = CGAL::to_double(pts[i].x() - pts[i - 1].x());
    const double dy = CGAL::to_double(pts[i].y() - pts[i - 1].y());
    out += std::sqrt(dx * dx + dy * dy);
  }
  if (closed && !same_point_2(pts.front(), pts.back())) {
    const double dx = CGAL::to_double(pts.front().x() - pts.back().x());
    const double dy = CGAL::to_double(pts.front().y() - pts.back().y());
    out += std::sqrt(dx * dx + dy * dy);
  }
  return out;
}

static void write_point(std::ostream& out, const Point_2& p, const double y) {
  out << "[" << CGAL::to_double(p.x()) << "," << y << "," << CGAL::to_double(p.y()) << "]";
}

static void write_polyline(std::ostream& out, const std::vector<Point_2>& pts, const double y) {
  out << "[";
  for (std::size_t i = 0; i < pts.size(); ++i) {
    if (i) out << ",";
    write_point(out, pts[i], y);
  }
  out << "]";
}

static double edge_angle(const Point_2& a, const Point_2& b) {
  return std::atan2(CGAL::to_double(b.y() - a.y()), CGAL::to_double(b.x() - a.x()));
}

static std::vector<Kernel::Direction_2> edge_directions_for(
  const std::vector<Point_2>& pts,
  const bool closed,
  const double global_angle_deg
) {
  std::vector<Kernel::Direction_2> out;
  const double theta = global_angle_deg * CGAL_PI / 180.0;
  const double theta_orth = theta + CGAL_PI / 2.0;
  const std::size_t n_edges = closed ? pts.size() : pts.size() - 1;
  for (std::size_t i = 0; i < n_edges; ++i) {
    const Point_2& a = pts[i];
    const Point_2& b = pts[(i + 1) % pts.size()];
    const double e = edge_angle(a, b);
    const double d0 = std::fabs(std::atan2(std::sin(e - theta), std::cos(e - theta)));
    const double d1 = std::fabs(std::atan2(std::sin(e - theta_orth), std::cos(e - theta_orth)));
    const double t = std::min(d0, CGAL_PI - d0) <= std::min(d1, CGAL_PI - d1) ? theta : theta_orth;
    out.emplace_back(std::cos(t), std::sin(t));
  }
  return out;
}

struct Item {
  std::vector<Point_2> raw;
  std::vector<Point_2> regularized;
  bool closed = false;
  double length = 0.0;
};

static bool load_mesh(const std::string& mesh_path, Mesh& mesh) {
  if (!CGAL::IO::read_polygon_mesh(mesh_path, mesh)) {
    std::vector<Point_3> points;
    std::vector<std::vector<std::size_t>> polygons;
    if (!CGAL::IO::read_polygon_soup(mesh_path, points, polygons)) {
      return false;
    }
    PMP::repair_polygon_soup(points, polygons);
    PMP::orient_polygon_soup(points, polygons);
    PMP::polygon_soup_to_polygon_mesh(points, polygons, mesh);
  }
  return !mesh.is_empty();
}

static std::vector<Item> slice_items(
  Slicer& slicer,
  const double y,
  const double max_offset,
  const double min_length,
  const bool use_global_angle,
  const double global_angle_deg,
  std::size_t& raw_count
) {
  std::vector<std::vector<Point_3>> polylines_3;
  slicer(Plane_3(0.0, 1.0, 0.0, -y), std::back_inserter(polylines_3));
  raw_count = polylines_3.size();
  std::vector<Item> items;
  for (const auto& poly3 : polylines_3) {
    if (poly3.size() < 2) continue;
    Item item;
    for (const auto& p : poly3) item.raw.emplace_back(p.x(), p.z());
    item.closed = item.raw.size() >= 3 && same_point_2(item.raw.front(), item.raw.back());
    if (item.closed && same_point_2(item.raw.front(), item.raw.back())) item.raw.pop_back();
    item.length = length_2(item.raw, item.closed);
    if (item.length < min_length) continue;

    if (item.closed && item.raw.size() >= 3) {
      if (use_global_angle) {
        using Directions = Contours::User_defined_directions_2<Kernel, std::vector<Point_2>>;
        auto edge_dirs = edge_directions_for(item.raw, true, global_angle_deg);
        Directions directions(item.raw, true, edge_dirs);
        Contours::regularize_closed_contour(
          item.raw, directions, std::back_inserter(item.regularized),
          CGAL::parameters::maximum_offset(max_offset));
      } else {
        using Directions = Contours::Longest_direction_2<Kernel, std::vector<Point_2>>;
        Directions directions(item.raw, true);
        Contours::regularize_closed_contour(
          item.raw, directions, std::back_inserter(item.regularized),
          CGAL::parameters::maximum_offset(max_offset));
      }
    } else if (item.raw.size() >= 2) {
      if (use_global_angle) {
        using Directions = Contours::User_defined_directions_2<Kernel, std::vector<Point_2>>;
        auto edge_dirs = edge_directions_for(item.raw, false, global_angle_deg);
        Directions directions(item.raw, false, edge_dirs);
        Contours::regularize_open_contour(
          item.raw, directions, std::back_inserter(item.regularized),
          CGAL::parameters::maximum_offset(max_offset));
      } else {
        using Directions = Contours::Longest_direction_2<Kernel, std::vector<Point_2>>;
        Directions directions(item.raw, false);
        Contours::regularize_open_contour(
          item.raw, directions, std::back_inserter(item.regularized),
          CGAL::parameters::maximum_offset(max_offset));
      }
    }
    items.push_back(std::move(item));
  }

  std::sort(items.begin(), items.end(), [](const Item& a, const Item& b) {
    return a.length > b.length;
  });
  return items;
}

static void write_slice_json(
  std::ostream& out,
  const Mesh& mesh,
  const double y,
  const std::vector<Item>& items,
  const std::size_t raw_count
) {
  out << "{";
  out << "\"y\":" << y << ",";
  out << "\"mesh_vertices\":" << mesh.number_of_vertices() << ",";
  out << "\"mesh_faces\":" << mesh.number_of_faces() << ",";
  out << "\"raw_polyline_count\":" << raw_count << ",";
  out << "\"contours\":[";
  for (std::size_t i = 0; i < items.size(); ++i) {
    if (i) out << ",";
    out << "{";
    out << "\"closed\":" << (items[i].closed ? "true" : "false") << ",";
    out << "\"length\":" << items[i].length << ",";
    out << "\"raw\":";
    write_polyline(out, items[i].raw, y);
    out << ",\"regularized\":";
    write_polyline(out, items[i].regularized, y);
    out << "}";
  }
  out << "]}";
}

int main(int argc, char** argv) {
  if (argc < 4) {
    std::cerr << "uso: slice_contours mesh.obj y out.json [max_offset] [min_length] [angle]\n"
              << "  o: slice_contours mesh.obj --batch heights.txt out.json [max_offset] [min_length] [angle]\n";
    return 1;
  }
  const std::string mesh_path = argv[1];
  const bool batch = std::string(argv[2]) == "--batch";
  if (batch && argc < 5) return 1;
  const int option_start = batch ? 5 : 4;
  const std::string out_path = batch ? argv[4] : argv[3];
  const double max_offset = argc > option_start ? std::atof(argv[option_start]) : 0.20;
  const double min_length = argc > option_start + 1 ? std::atof(argv[option_start + 1]) : 0.30;
  const bool use_global_angle = argc > option_start + 2;
  const double global_angle_deg = use_global_angle ? std::atof(argv[option_start + 2]) : 0.0;

  Mesh mesh;
  if (!load_mesh(mesh_path, mesh)) {
    std::cerr << "lettura mesh fallita: " << mesh_path << "\n";
    return 1;
  }
  std::vector<double> heights;
  if (batch) {
    std::ifstream input(argv[3]);
    double y = 0.0;
    while (input >> y) heights.push_back(y);
  } else {
    heights.push_back(std::atof(argv[2]));
  }
  if (heights.empty()) {
    std::cerr << "nessuna quota da elaborare\n";
    return 1;
  }

  std::ofstream out(out_path);
  if (!out) {
    std::cerr << "scrittura fallita: " << out_path << "\n";
    return 1;
  }
  out << std::fixed << std::setprecision(8);
  if (batch) out << "{\"slices\":[";
  Slicer slicer(mesh);
  for (std::size_t h = 0; h < heights.size(); ++h) {
    std::size_t raw_count = 0;
    const auto items = slice_items(
      slicer, heights[h], max_offset, min_length,
      use_global_angle, global_angle_deg, raw_count);
    if (batch && h) out << ",";
    write_slice_json(out, mesh, heights[h], items, raw_count);
    std::cout << "slicer raw=" << raw_count
              << " kept=" << items.size()
              << " y=" << heights[h] << "\n";
  }
  if (batch) out << "]}";

  return 0;
}
