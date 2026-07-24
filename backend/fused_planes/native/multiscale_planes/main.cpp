#include <CGAL/Exact_predicates_inexact_constructions_kernel.h>
#include <CGAL/Point_set_3.h>
#include <CGAL/Point_set_3/IO.h>
#include <CGAL/Shape_detection/Region_growing/Point_set.h>
#include <CGAL/Shape_detection/Region_growing/Region_growing.h>

#include <algorithm>
#include <cmath>
#include <cstddef>
#include <fstream>
#include <iomanip>
#include <iostream>
#include <limits>
#include <string>
#include <vector>

using Kernel = CGAL::Exact_predicates_inexact_constructions_kernel;
using Point = Kernel::Point_3;
using Vector = Kernel::Vector_3;
using Plane = Kernel::Plane_3;
using Point_set = CGAL::Point_set_3<Point>;
using Region_type = CGAL::Shape_detection::Point_set::
    Least_squares_plane_fit_region_for_point_set<Point_set>;
using Neighbor_query = CGAL::Shape_detection::Point_set::
    K_neighbor_query_for_point_set<Point_set>;
using Sorting = CGAL::Shape_detection::Point_set::
    Least_squares_plane_fit_sorting_for_point_set<Point_set, Neighbor_query>;
using Region_growing = CGAL::Shape_detection::
    Region_growing<Neighbor_query, Region_type>;

namespace {

Vector unit(Vector vector) {
  const double length = std::sqrt(vector.squared_length());
  return length > 1e-15 ? vector / length : Vector(0.0, 0.0, 1.0);
}

Vector canonical(Vector normal) {
  normal = unit(normal);
  const double values[3] = {normal.x(), normal.y(), normal.z()};
  int largest = 0;
  if (std::abs(values[1]) > std::abs(values[largest])) largest = 1;
  if (std::abs(values[2]) > std::abs(values[largest])) largest = 2;
  return values[largest] < 0.0 ? -normal : normal;
}

}  // namespace

int main(int argc, char** argv) {
  if (argc != 8) {
    std::cerr << "usage: cgal_multiscale_planes input.ply regions.csv labels.csv "
                 "k max_distance max_angle min_region_size\n";
    return 2;
  }

  const std::string input_path = argv[1];
  const std::string regions_path = argv[2];
  const std::string labels_path = argv[3];
  const std::size_t k = static_cast<std::size_t>(std::stoul(argv[4]));
  const double max_distance = std::stod(argv[5]);
  const double max_angle = std::stod(argv[6]);
  const std::size_t min_region_size =
      static_cast<std::size_t>(std::stoul(argv[7]));

  Point_set points(true);
  std::ifstream input(input_path, std::ios::binary);
  if (!input || !(input >> points) || points.empty() || !points.has_normal_map()) {
    std::cerr << "failed to read point set with normals: " << input_path << "\n";
    return 1;
  }

  std::cerr << "points=" << points.size() << " k=" << k
            << " distance=" << max_distance << " angle=" << max_angle
            << " min_region=" << min_region_size << "\n";

  Neighbor_query neighbors =
      CGAL::Shape_detection::Point_set::make_k_neighbor_query(
          points, CGAL::parameters::k_neighbors(k));
  Sorting sorting =
      CGAL::Shape_detection::Point_set::make_least_squares_plane_fit_sorting(
          points, neighbors);
  sorting.sort();

  Region_type region_type =
      CGAL::Shape_detection::Point_set::make_least_squares_plane_fit_region(
          points,
          CGAL::parameters::maximum_distance(max_distance)
              .maximum_angle(max_angle)
              .minimum_region_size(min_region_size));
  Region_growing growing(points, sorting.ordered(), neighbors, region_type);
  std::vector<Region_growing::Primitive_and_region> regions;
  growing.detect(std::back_inserter(regions));

  std::vector<long long> labels(points.size(), -1);
  std::ofstream csv(regions_path);
  csv << std::setprecision(12);
  csv << "region,npoints,nx,ny,nz,d,cx,cy,cz,umin,umax,vmin,vmax,rms\n";

  const Vector world_up(0.0, 1.0, 0.0);
  for (std::size_t region_id = 0; region_id < regions.size(); ++region_id) {
    const auto& members = regions[region_id].second;
    if (members.empty()) continue;

    Vector normal = canonical(regions[region_id].first.orthogonal_vector());
    const Point origin = regions[region_id].first.projection(
        get(points.point_map(), members.front()));
    const double d = -(normal.x() * origin.x() + normal.y() * origin.y() +
                       normal.z() * origin.z());

    Vector up_on_plane = world_up - normal * (world_up * normal);
    if (up_on_plane.squared_length() < 1e-10) {
      up_on_plane = Vector(1.0, 0.0, 0.0) -
                    normal * (Vector(1.0, 0.0, 0.0) * normal);
    }
    const Vector v_axis = unit(up_on_plane);
    const Vector u_axis = unit(CGAL::cross_product(v_axis, normal));

    double cx = 0.0, cy = 0.0, cz = 0.0;
    double umin = std::numeric_limits<double>::max();
    double umax = std::numeric_limits<double>::lowest();
    double vmin = std::numeric_limits<double>::max();
    double vmax = std::numeric_limits<double>::lowest();
    double squared_error = 0.0;
    for (const auto item : members) {
      const Point point = get(points.point_map(), item);
      const std::size_t index = static_cast<std::size_t>(item);
      if (index < labels.size()) labels[index] = static_cast<long long>(region_id);
      cx += point.x();
      cy += point.y();
      cz += point.z();
      const Vector delta = point - origin;
      const double u = delta * u_axis;
      const double v = delta * v_axis;
      umin = std::min(umin, u);
      umax = std::max(umax, u);
      vmin = std::min(vmin, v);
      vmax = std::max(vmax, v);
      const double distance = normal.x() * point.x() + normal.y() * point.y() +
                              normal.z() * point.z() + d;
      squared_error += distance * distance;
    }
    const double count = static_cast<double>(members.size());
    csv << region_id << ',' << members.size() << ',' << normal.x() << ','
        << normal.y() << ',' << normal.z() << ',' << d << ',' << cx / count
        << ',' << cy / count << ',' << cz / count << ',' << umin << ',' << umax
        << ',' << vmin << ',' << vmax << ','
        << std::sqrt(squared_error / count) << '\n';
  }

  std::ofstream label_output(labels_path);
  label_output << "point,region\n";
  for (std::size_t index = 0; index < labels.size(); ++index) {
    label_output << index << ',' << labels[index] << '\n';
  }

  std::vector<Region_type::Item> unassigned;
  growing.unassigned_items(points, std::back_inserter(unassigned));
  std::cerr << "regions=" << regions.size()
            << " assigned=" << (points.size() - unassigned.size())
            << " unassigned=" << unassigned.size() << "\n";
  return 0;
}
